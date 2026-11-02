// segment.jai's kernel on Direct3D 11: a device of its own (the renderer's immediate context belongs to
// the UI thread), M and F as structured buffers bound for unordered access, F read back through a staging
// copy. Used under seg.mu only.

#scope_module

cs_init :: (m_floats: int) -> bool {
	levels := D3D_FEATURE_LEVEL.[._11_0];
	hr := D3D11CreateDevice(null, .HARDWARE, null, 0, levels.data, 1, D3D11_SDK_VERSION, *cs.device, null, *cs.ctx);
	if FAILED(hr) hr = D3D11CreateDevice(null, .WARP, null, 0, levels.data, 1, D3D11_SDK_VERSION, *cs.device, null, *cs.ctx);
	if FAILED(hr) return false;
	code, errs, chr := D3DCompile(kernel_source(.HLSL), "fc_segment", .[], null, "cs_main", "cs_5_0", 0, 0);
	defer { free(code); free(errs); }
	if FAILED(chr) {
		log_error("video: segment kernel: %", errs);
		return false;
	}
	if FAILED(ID3D11Device_CreateComputeShader(cs.device, code.data, xx code.count, null, *cs.shader)) return false;
	cbd := D3D11_BUFFER_DESC.{ByteWidth = 64, Usage = .DYNAMIC, BindFlags = .CONSTANT_BUFFER, CPUAccessFlags = .WRITE};
	if FAILED(ID3D11Device_CreateBuffer(cs.device, *cbd, null, *cs.cbuf)) return false;
	cs.m, cs.m_uav = buffer(m_floats);
	return cs.m != null;
}

cs_resize :: (bytes: int) -> bool {
	safe_release(cs.f_uav);
	safe_release(cs.f);
	safe_release(cs.f_read);
	cs.f, cs.f_uav = buffer(bytes / 4);
	sd := D3D11_BUFFER_DESC.{ByteWidth = xx bytes, Usage = .STAGING, CPUAccessFlags = .READ};
	if !cs.f || FAILED(ID3D11Device_CreateBuffer(cs.device, *sd, null, *cs.f_read)) return false;
	return true;
}

cs_write_m :: (at: int, data: []float32) {
	box := D3D11_BOX.{left = xx (at * 4), right = xx ((at + data.count) * 4), bottom = 1, back = 1};
	ID3D11DeviceContext_UpdateSubresource(cs.ctx, cs.m, 0, *box, data.data, 0, 0);
}

cs_write_f :: (at: int, data: []u8) {
	box := D3D11_BOX.{left = xx at, right = xx (at + data.count), bottom = 1, back = 1};
	ID3D11DeviceContext_UpdateSubresource(cs.ctx, cs.f, 0, *box, data.data, 0, 0);
}

cs_run :: (passes: []Pass) {
	ID3D11DeviceContext_CSSetShader(cs.ctx, cs.shader, null, 0);
	ID3D11DeviceContext_CSSetConstantBuffers(cs.ctx, 0, 1, *cs.cbuf);
	uavs := (*ID3D11UnorderedAccessView).[cs.m_uav, cs.f_uav];
	ID3D11DeviceContext_CSSetUnorderedAccessViews(cs.ctx, 0, 2, uavs.data, null);
	for passes {
		mapped: D3D11_MAPPED_SUBRESOURCE;
		if FAILED(ID3D11DeviceContext_Map(cs.ctx, cs.cbuf, 0, .WRITE_DISCARD, 0, *mapped)) return;
		memcpy(mapped.pData, it.p.data, size_of(type_of(it.p)));
		ID3D11DeviceContext_Unmap(cs.ctx, cs.cbuf, 0);
		ID3D11DeviceContext_Dispatch(cs.ctx, xx ((it.n + 63) / 64), 1, 1);
	}
}

cs_read_f :: (at: int, out: []u8) -> bool {
	box := D3D11_BOX.{left = xx at, right = xx (at + out.count), bottom = 1, back = 1};
	ID3D11DeviceContext_CopySubresourceRegion(cs.ctx, cs.f_read, 0, 0, 0, 0, cs.f, 0, *box);
	mapped: D3D11_MAPPED_SUBRESOURCE;
	if FAILED(ID3D11DeviceContext_Map(cs.ctx, cs.f_read, 0, .READ, 0, *mapped)) return false;
	memcpy(out.data, mapped.pData, out.count);
	ID3D11DeviceContext_Unmap(cs.ctx, cs.f_read, 0);
	return true;
}

#scope_file

cs: struct {
	device: *ID3D11Device;
	ctx: *ID3D11DeviceContext;
	shader: *ID3D11ComputeShader;
	cbuf: *ID3D11Buffer;
	m, f, f_read: *ID3D11Buffer;
	m_uav, f_uav: *ID3D11UnorderedAccessView;
};

// A structured buffer of n 4-byte elements and its unordered access view.
buffer :: (n: int) -> *ID3D11Buffer, *ID3D11UnorderedAccessView {
	bd := D3D11_BUFFER_DESC.{ByteWidth = xx (n * 4), Usage = .DEFAULT, BindFlags = .UNORDERED_ACCESS, MiscFlags = .BUFFER_STRUCTURED, StructureByteStride = 4};
	b: *ID3D11Buffer;
	if FAILED(ID3D11Device_CreateBuffer(cs.device, *bd, null, *b)) return null, null;
	ud := D3D11_UNORDERED_ACCESS_VIEW_DESC.{Format = .UNKNOWN, ViewDimension = .BUFFER};
	ud.Buffer.NumElements = xx n;
	v: *ID3D11UnorderedAccessView;
	if FAILED(ID3D11Device_CreateUnorderedAccessView(cs.device, b, *ud, *v)) { IUnknown_Release(b); return null, null; }
	return b, v;
}
