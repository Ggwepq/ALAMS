import 'package:flutter/foundation.dart';

/// Unified model for spoof detection results.
class SpoofResult {
  final bool isReal;
  final double confidence;
  final List<dynamic>? diagnostics;
  final Uint8List? faceCrop;

  SpoofResult({
    required this.isReal,
    required this.confidence,
    this.diagnostics,
    this.faceCrop,
  });

  @override
  String toString() => 'SpoofResult(isReal: $isReal, confidence: ${confidence.toStringAsFixed(4)})';
}
