import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Converts a YUV420 / NV21 [CameraImage] into an [InputImage] suitable for
/// Google ML Kit on Android.
///
/// ML Kit's Android native layer accepts **only NV21** when using
/// [InputImage.fromBytes]. Passing YUV_420_888 directly causes the
/// `InputImageConverterError: ImageFormat is not supported` exception.
///
/// This utility manually interleaves the U and V planes into the NV21 layout
/// (Y plane followed by interleaved V/U bytes) so ML Kit can process it.
InputImage? buildInputImageForMLKit({
  required CameraImage image,
  required CameraDescription camera,
}) {
  if (image.planes.isEmpty) return null;

  // Compute the rotation from the sensor orientation.
  final rotation =
      InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
          InputImageRotation.rotation0deg;

  final int width = image.width;
  final int height = image.height;

  // ML Kit only accepts NV21 via fromBytes on Android.
  // NV21 layout: Y plane (width*height bytes) + interleaved VU plane.
  final Uint8List nv21Bytes = _yuv420ToNv21(image);

  return InputImage.fromBytes(
    bytes: nv21Bytes,
    metadata: InputImageMetadata(
      size: Size(width.toDouble(), height.toDouble()),
      rotation: rotation,
      format: InputImageFormat.nv21,
      bytesPerRow: width, // NV21 Y row stride equals width
    ),
  );
}

/// Converts YUV_420_888 planes (from Flutter camera) to a single NV21 byte array.
/// NV21 is: [Y0,Y1,...,Yn, V0,U0, V1,U1, ..., Vn,Un]
Uint8List _yuv420ToNv21(CameraImage image) {
  final int width = image.width;
  final int height = image.height;

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  final int ySize = width * height;
  final int uvSize = width * height ~/ 2; // NV21 UV size

  final nv21 = Uint8List(ySize + uvSize);

  // Copy Y plane row by row (handle non-contiguous stride)
  final int yRowStride = yPlane.bytesPerRow;
  for (int row = 0; row < height; row++) {
    final srcOffset = row * yRowStride;
    final dstOffset = row * width;
    nv21.setRange(dstOffset, dstOffset + width, yPlane.bytes, srcOffset);
  }

  // Interleave V and U planes into NV21 UV section: [V, U, V, U, ...]
  final int uvRowStride = uPlane.bytesPerRow;
  final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
  int uvIndex = ySize;

  for (int row = 0; row < height ~/ 2; row++) {
    for (int col = 0; col < width ~/ 2; col++) {
      final int bufIndex = row * uvRowStride + col * uvPixelStride;
      nv21[uvIndex++] = vPlane.bytes[bufIndex]; // V first in NV21
      nv21[uvIndex++] = uPlane.bytes[bufIndex]; // then U
    }
  }

  return nv21;
}
