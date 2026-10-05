import '../llm/cancellation.dart';
import 'models.dart';

/// Thresholds belong to different model scales and must never be interchanged.
final class RagRetrievalConfig {
  const RagRetrievalConfig({
    this.denseThreshold = 0.45,
    this.rerankThreshold = 0,
    this.calibrationId = 'uncalibrated',
    this.expectedRerankerFingerprint,
    this.corpusHash,
    this.embeddingFingerprint,
    this.strategy,
    this.rewriteModel,
  });
  final double denseThreshold, rerankThreshold;
  final String calibrationId;
  final String? expectedRerankerFingerprint;
  final String? corpusHash, embeddingFingerprint, rewriteModel;
  final ChunkStrategy? strategy;
  factory RagRetrievalConfig.fromProfile(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['score_scale'] != 'bge_raw_logit' ||
        json['rewrite_version'] != 'query-rewrite-v1') {
      throw const FormatException('Incompatible calibration profile');
    }
    try {
      final model = json['rewrite_model'] as Map;
      final provider = (model['providerId'] as Map)['value'] as String;
      final modelId = (model['modelId'] as Map)['value'] as String;
      if (provider.isEmpty || modelId.isEmpty) {
        throw const FormatException('Empty rewrite model');
      }
      final result = RagRetrievalConfig(
        denseThreshold: ((json['dense'] as Map)['threshold'] as num).toDouble(),
        rerankThreshold: ((json['rerank'] as Map)['threshold'] as num)
            .toDouble(),
        calibrationId: json['id'] as String,
        expectedRerankerFingerprint: json['reranker_fingerprint'] as String,
        corpusHash: json['corpus_hash'] as String,
        embeddingFingerprint: json['embedding_fingerprint'] as String,
        strategy: ChunkStrategy.values.byName(json['strategy'] as String),
        rewriteModel: '$provider/$modelId',
      );
      result.validate();
      return result;
    } on FormatException {
      rethrow;
    } on TypeError {
      throw const FormatException('Malformed calibration profile');
    } on ArgumentError {
      throw const FormatException('Invalid calibration profile values');
    }
  }
  Map<String, Object?> toJson() => {
    'dense_threshold': denseThreshold,
    'rerank_threshold': rerankThreshold,
    'calibration_id': calibrationId,
    'expected_reranker_fingerprint': expectedRerankerFingerprint,
    'corpus_hash': corpusHash,
    'embedding_fingerprint': embeddingFingerprint,
    'strategy': strategy?.name,
    'rewrite_model': rewriteModel,
    'overlap_fraction': 0.75,
  };
  void validate() {
    if (!denseThreshold.isFinite ||
        denseThreshold < -1 ||
        denseThreshold > 1 ||
        !rerankThreshold.isFinite ||
        calibrationId.isEmpty) {
      throw ArgumentError('Invalid retrieval configuration');
    }
  }
}

final class RagRewriteResult {
  const RagRewriteResult({
    required this.query,
    this.fallbackReason,
    this.audit = const {},
  });
  final String query;
  final String? fallbackReason;
  final Map<String, Object?> audit;
}

abstract interface class RagQueryRewriter {
  Future<RagRewriteResult> rewrite(String original, CancellationToken token);
}

final class RagRerankerInfo {
  const RagRerankerInfo({required this.fingerprint, required this.scale});
  final String fingerprint, scale;
}

abstract interface class RagReranker {
  Future<RagRerankerInfo> rerankerInfo(CancellationToken token);
  Future<RagRerankResult> rerank(
    String query,
    List<RagHit> candidates,
    RagRerankerInfo model,
    CancellationToken token,
  );
}

final class RagRerankResult {
  RagRerankResult(Map<String, double> scores, {Map<String, Object?>? usage})
    : scores = Map.unmodifiable(scores),
      usage = usage == null ? null : Map.unmodifiable(usage);
  final Map<String, double> scores;
  final Map<String, Object?>? usage;
}

bool overlappingRagEvidence(RagChunk a, RagChunk b) {
  if (a.documentId != b.documentId ||
      a.documentRevision != b.documentRevision) {
    return false;
  }
  final shortest = (a.end - a.start) < (b.end - b.start)
      ? a.end - a.start
      : b.end - b.start;
  final left = a.start > b.start ? a.start : b.start;
  final right = a.end < b.end ? a.end : b.end;
  return shortest > 0 && right > left && (right - left) / shortest >= 0.75;
}
