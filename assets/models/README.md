## FaceNet TFLite Model Placeholder

Place your FaceNet TFLite model here as:

  `assets/models/facenet.tflite`

### Where to get it

You can use the standard FaceNet architecture (which comes in various float sizes like 128 or 512 dimensions). Note: The code is dynamic and will adapt to 128 or 512!

1. **Pre-converted standard FaceNet model** (160x160 input, 128/512 output):
   Look for `facenet.tflite` online (e.g. at https://github.com/shaqian/tflite-models/tree/master/facenet or similar repos with FaceNet).

### Expected Model I/O

| Property | Value |
|----------|-------|
| Input tensor shape | `[1, 160, 160, 3]` (float32) |
| Input normalization | pixels / 127.5 - 1.0 → range [-1, 1] |
| Output tensor shape | `[1, 128]` or `[1, 512]` (float32 embedding vector) |

*If FaceNet causes lag/overheating, we can switch back to MobileFaceNet by simply swapping the .tflite file back and restoring the 112x112 target size in `face_recognition_service.dart`.*