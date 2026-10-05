"""Deterministic gateway protocol tests; not real-model quality evidence."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

from fastapi import HTTPException

spec = importlib.util.spec_from_file_location(
    "rag_gateway", Path(__file__).parents[3] / "tool/rag_model_service/app.py")
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class Tokenizer:
    def __call__(self, query, passage=None, **kwargs):
        return {"input_ids": list(range(len(query) + (len(passage) + 4 if passage else 0)))}


class GatewayProtocolTest(unittest.TestCase):
    def test_pair_ids_logit_scale_and_rejection(self):
        model = {"model": "TEST"}
        fingerprint = gateway.digest(model)
        body = gateway.RerankInput(query="q", expected_model_fingerprint=fingerprint,
            candidates=[gateway.RerankCandidate(id="a", text="a"),
                        gateway.RerankCandidate(id="b", text="b")])
        result = {"results": [{"index": 1, "relevance_score": 3.5},
                              {"index": 0, "relevance_score": -5.2}]}
        transport = MagicMock()
        transport.__enter__.return_value.post.return_value.raise_for_status.return_value.json.side_effect = lambda: result
        with patch.object(gateway, "reranker_config", return_value=(model, "TEST")), \
             patch.object(gateway, "tokenizer", return_value=Tokenizer()), \
             patch.object(gateway.httpx, "Client", return_value=transport):
            actual = gateway.rerank(body)
            self.assertEqual(actual["score_scale"], "bge_raw_logit")
            self.assertEqual(actual["outputs"], [{"id": "b", "score": 3.5}, {"id": "a", "score": -5.2}])
            for broken in [[{"index": 0, "relevance_score": 1}],
                           [{"index": 0, "relevance_score": 1}, {"index": 0, "relevance_score": 2}],
                           [{"index": True, "relevance_score": 1}, {"index": 0, "relevance_score": 2}],
                           [{"index": 1, "relevance_score": True}, {"index": 0, "relevance_score": 2}],
                           [{"index": 1, "relevance_score": -1e6}, {"index": 0, "relevance_score": 2}],
                           [{"index": 1, "relevance_score": float("nan")}, {"index": 0, "relevance_score": 2}]]:
                result = {"results": broken}
                with self.assertRaises(HTTPException) as error:
                    gateway.rerank(body)
                self.assertEqual(error.exception.status_code, 502)
            body.expected_model_fingerprint = "changed"
            with self.assertRaises(HTTPException) as error:
                gateway.rerank(body)
            self.assertEqual(error.exception.status_code, 409)
            body.expected_model_fingerprint = fingerprint
            body.query = "q" * 1025
            with self.assertRaises(HTTPException) as error:
                gateway.rerank(body)
            self.assertEqual(error.exception.detail, "reranker_query_too_long")
            body.query = "q"
            body.candidates[0].text = "x" * 8192
            with self.assertRaises(HTTPException) as error:
                gateway.rerank(body)
            self.assertEqual(error.exception.detail, "reranker_pair_too_long")


if __name__ == "__main__":
    unittest.main()
