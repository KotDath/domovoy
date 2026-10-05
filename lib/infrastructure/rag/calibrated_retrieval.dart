// Generated from eval/rag/calibration.json. Contains no evaluation questions.
import '../../core/rag/retrieval.dart';

const Map<String, dynamic> ragCalibrationProfile = {
  "version": 1,
  "dev_hash":
      "c04cd94f280049551160febceff861dc0c46366259a1959bdadd6d77569fef33",
  "strategy": "fixed",
  "corpus_hash":
      "6d4924c95fcd8734301baad62707b74084685c20950e7b9fa07858f6db7fea31",
  "embedding_fingerprint":
      "df2af910c83efd01d39f7ba4012e24bdc1ba98281ad65efff841fd025148279d",
  "reranker_fingerprint":
      "f957e0296c0c54f93096d80bb84aa0326ba4910f400a0b58453467c02a218874",
  "score_scale": "bge_raw_logit",
  "rewrite_version": "query-rewrite-v1",
  "rewrite_model": {
    "type": "llm.model_ref",
    "version": 1,
    "providerId": {
      "type": "llm.provider_id",
      "version": 1,
      "value": "deepseek",
    },
    "modelId": {
      "type": "llm.model_id",
      "version": 1,
      "value": "deepseek-flash",
    },
  },
  "rewrite_sampling": {
    "temperature": 0,
    "max_output_tokens": 512,
    "reasoning": "disabled",
  },
  "dense": {
    "threshold": 0.5360335140418512,
    "question_f1": 0.7692307692307693,
    "sent_passage_precision": 0.3181818181818182,
    "known_hit": 5,
    "known_miss": 3,
    "unknown_nonempty": 0,
    "unknown_empty": 8,
    "relevant_sent": 7,
    "total_sent": 22,
    "observed_min": 0.2829216067425871,
    "observed_max": 0.7931694539016764,
    "sample_count": 16,
    "cutoff_count": 321,
    "objective": "question F1, sent-passage precision, higher cutoff; dev only",
  },
  "rerank": {
    "threshold": -1.090676486492157,
    "question_f1": 0.8888888888888888,
    "sent_passage_precision": 0.45454545454545453,
    "known_hit": 4,
    "known_miss": 0,
    "unknown_nonempty": 1,
    "unknown_empty": 3,
    "relevant_sent": 5,
    "total_sent": 11,
    "observed_min": -11.027076721191406,
    "observed_max": 3.5745391845703125,
    "sample_count": 8,
    "cutoff_count": 161,
    "objective": "question F1, sent-passage precision, higher cutoff; dev only",
  },
  "relevance_label": "agent-selected canonical spans; >=50% span overlap",
  "created_at_utc": "2026-10-05T00:07:45.877971Z",
  "id": "1f9f5dca5d15ff87125be06cc04bc699f7c9b5f8da2c6d1cd43a9da53997cd28",
};

final calibratedRagRetrieval = RagRetrievalConfig.fromProfile(
  ragCalibrationProfile,
);
