package opus

// Port of libopus 1.3.1 src/mlp.c (BSD, see range.odin): the small dense/GRU
// network used by the tonality analysis for speech/music and activity probability.

import "core:math"

MLP_WEIGHTS_SCALE :: f32(1.0 / 128)
MLP_MAX_NEURONS :: 32

Mlp_Dense_Layer :: struct {
	bias:          []i8,
	input_weights: []i8,
	nb_inputs:     int,
	nb_neurons:    int,
	sigmoid:       bool,
}

Mlp_Gru_Layer :: struct {
	bias:              []i8,
	input_weights:     []i8,
	recurrent_weights: []i8,
	nb_inputs:         int,
	nb_neurons:        int,
}

mlp_layer0 :: proc "contextless" () -> Mlp_Dense_Layer {
	return {mlp_layer0_bias[:], mlp_layer0_weights[:], 25, 32, false}
}
mlp_layer1 :: proc "contextless" () -> Mlp_Gru_Layer {
	return {mlp_layer1_bias[:], mlp_layer1_weights[:], mlp_layer1_recur_weights[:], 32, 24}
}
mlp_layer2 :: proc "contextless" () -> Mlp_Dense_Layer {
	return {mlp_layer2_bias[:], mlp_layer2_weights[:], 24, 2, true}
}

mlp_tansig_approx :: proc "contextless" (x_: f32) -> f32 {
	x := x_
	// Tests are reversed to catch NaNs
	if !(x < 8) do return 1
	if !(x > -8) do return -1
	if x != x do return 0
	sign := f32(1)
	if x < 0 {
		x = -x
		sign = -1
	}
	i := int(math.floor(0.5 + 25 * x))
	x -= 0.04 * f32(i)
	y := mlp_tansig_table[i]
	dy := 1 - y * y
	y = y + x * dy * (1 - y * x)
	return sign * y
}

mlp_sigmoid_approx :: #force_inline proc "contextless" (x: f32) -> f32 {
	return 0.5 + 0.5 * mlp_tansig_approx(0.5 * x)
}

mlp_gemm_accum :: proc "contextless" (out: []f32, weights: []i8, rows, cols, col_stride: int, x: []f32) {
	for i in 0 ..< rows {
		for j in 0 ..< cols {
			out[i] += f32(weights[j * col_stride + i]) * x[j]
		}
	}
}

mlp_compute_dense :: proc "contextless" (layer: ^Mlp_Dense_Layer, output: []f32, input: []f32) {
	M := layer.nb_inputs
	N := layer.nb_neurons
	for i in 0 ..< N do output[i] = f32(layer.bias[i])
	mlp_gemm_accum(output, layer.input_weights, N, M, N, input)
	for i in 0 ..< N do output[i] *= MLP_WEIGHTS_SCALE
	if layer.sigmoid {
		for i in 0 ..< N do output[i] = mlp_sigmoid_approx(output[i])
	} else {
		for i in 0 ..< N do output[i] = mlp_tansig_approx(output[i])
	}
}

mlp_compute_gru :: proc "contextless" (gru: ^Mlp_Gru_Layer, state: []f32, input: []f32) {
	tmp, z, r, h: [MLP_MAX_NEURONS]f32
	M := gru.nb_inputs
	N := gru.nb_neurons
	stride := 3 * N
	// Update gate
	for i in 0 ..< N do z[i] = f32(gru.bias[i])
	mlp_gemm_accum(z[:], gru.input_weights, N, M, stride, input)
	mlp_gemm_accum(z[:], gru.recurrent_weights, N, N, stride, state)
	for i in 0 ..< N do z[i] = mlp_sigmoid_approx(MLP_WEIGHTS_SCALE * z[i])
	// Reset gate
	for i in 0 ..< N do r[i] = f32(gru.bias[N + i])
	mlp_gemm_accum(r[:], gru.input_weights[N:], N, M, stride, input)
	mlp_gemm_accum(r[:], gru.recurrent_weights[N:], N, N, stride, state)
	for i in 0 ..< N do r[i] = mlp_sigmoid_approx(MLP_WEIGHTS_SCALE * r[i])
	// Output
	for i in 0 ..< N do h[i] = f32(gru.bias[2 * N + i])
	for i in 0 ..< N do tmp[i] = state[i] * r[i]
	mlp_gemm_accum(h[:], gru.input_weights[2 * N:], N, M, stride, input)
	mlp_gemm_accum(h[:], gru.recurrent_weights[2 * N:], N, N, stride, tmp[:])
	for i in 0 ..< N do h[i] = z[i] * state[i] + (1 - z[i]) * mlp_tansig_approx(MLP_WEIGHTS_SCALE * h[i])
	for i in 0 ..< N do state[i] = h[i]
}
