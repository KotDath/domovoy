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
    bos_token_id = 0
    eos_token_id = 2
    sep_token_id = 2
    def __call__(self, query, passage=None, **kwargs):
        ids = list(range(len(query)))
        if passage is not None:
            ids = [0, *ids, 2, 2, *range(len(passage)), 2]
        return {"input_ids": ids}


class GatewayProtocolTest(unittest.TestCase):
    def test_pair_ids_logit_scale_and_rejection(self):
        model = {"model": "TEST"}
        fingerprint = gateway.digest(model)
        body = gateway.RerankInput(query="q", expected_model_fingerprint=fingerprint,
            candidates=[gateway.RerankCandidate(id="a", text="a"),
                        gateway.RerankCandidate(id="b", text="b")])
        result = {"usage": {"prompt_tokens": 12, "total_tokens": 12},
                  "results": [{"index": 1, "relevance_score": 3.5},
                              {"index": 0, "relevance_score": -5.2}]}
        transport = MagicMock()
        bad_tokens = False
        def post(url, json):
            response = MagicMock()
            data = {"tokens": list(range(len(json['content'])))} if url.endswith('/tokenize') else result
            if bad_tokens and url.endswith('/tokenize'):
                data['tokens'] = []
            response.raise_for_status.return_value.json.return_value = data
            return response
        transport.__enter__.return_value.post.side_effect = post
        with patch.object(gateway, "reranker_config", return_value=(model, "TEST")), \
             patch.object(gateway, "tokenizer", return_value=Tokenizer()), \
             patch.object(gateway.httpx, "Client", return_value=transport):
            actual = gateway.rerank(body)
            self.assertEqual(actual["score_scale"], "bge_raw_logit")
            self.assertEqual(actual["outputs"], [{"id": "b", "score": 3.5}, {"id": "a", "score": -5.2}])
            valid_result = result
            for broken in [[{"index": 0, "relevance_score": 1}],
                           [{"index": 0, "relevance_score": 1}, {"index": 0, "relevance_score": 2}],
                           [{"index": True, "relevance_score": 1}, {"index": 0, "relevance_score": 2}],
                           [{"index": 1, "relevance_score": True}, {"index": 0, "relevance_score": 2}],
                           [{"index": 1, "relevance_score": -1e6}, {"index": 0, "relevance_score": 2}],
                           [{"index": 1, "relevance_score": float("nan")}, {"index": 0, "relevance_score": 2}]]:
                result = {"usage": {"prompt_tokens": 12, "total_tokens": 12}, "results": broken}
                with self.assertRaises(HTTPException) as error:
                    gateway.rerank(body)
                self.assertEqual(error.exception.status_code, 502)
            result = valid_result
            bad_tokens = True
            with self.assertRaises(HTTPException) as error:
                gateway.rerank(body)
            self.assertEqual(error.exception.detail, 'reranker_tokenizer_mismatch')
            bad_tokens = False
            result = {**valid_result, 'usage': {'prompt_tokens': 0, 'total_tokens': 0}}
            with self.assertRaises(HTTPException) as error:
                gateway.rerank(body)
            self.assertEqual(error.exception.detail, 'reranker_token_usage_mismatch')
            result = valid_result
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
