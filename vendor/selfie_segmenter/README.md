# MediaPipe selfie segmenter (landscape)

The person mask behind the camera's background blur and replacement (`src/video/segment.jai`).
`selfie_segmenter_landscape.tflite` is Google's model file, unmodified:

- Model: https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_segmenter_landscape/float16/1/selfie_segmenter_landscape.tflite
- Model card: https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Selfie%20Segmentation.pdf
- sha256: 490e9ea734313e0de10fa0cd9e3c6133e36ea4db2b7a49bde9ef019f72796b8e
- Licence: Apache-2.0 (LICENSE, as for MediaPipe's models)

A 256x144 RGB input in [0, 1], one 256x144 output: the chance each pixel is a person. 106k float16
weights in 92 ops of a MobileNetV3-style encoder and decoder (convolutions, depthwise convolutions,
squeeze-and-excite, bilinear upsampling, MediaPipe's `Convolution2DTransposeBias`).

fastcord runs no TFLite: `tools/segmenter_convert.py` writes the op list as `src/video/segment_model.jai`,
whose ops point at their weights' offsets in this file, and the binary embeds the file (250 KB). Re-run
the tool when the model changes.
