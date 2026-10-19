"""Real gateway scheduling/codec with controlled HTTP and a virtual clock."""
import importlib.util
import json
import os
from concurrent.futures import ThreadPoolExecutor
from email.utils import formatdate
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

import httpx
from fastapi import HTTPException

spec = importlib.util.spec_from_file_location(
    'rate_limited_gateway', Path(__file__).parents[3] / 'tool/rag_model_service/app.py')
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class NeuralDeepRateLimitTest(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.starts = []
        self.payloads = []
        self.replies = []
        gateway.neuraldeep_next_request_at = 0.0
        self.transport = MagicMock()
        self.transport.__enter__.return_value.post.side_effect = self.post
        for setting in (patch.dict(os.environ, {'NDT_KEY': 'NOT_A_REAL_TOKEN'}),
                        patch.object(gateway, 'monotonic', lambda: self.now),
                        patch.object(gateway, 'wall_time', lambda: 1_800_000_000),
                        patch.object(gateway, 'sleep', self.advance),
                        patch.object(gateway.httpx, 'Client', return_value=self.transport)):
            setting.start()
            self.addCleanup(setting.stop)

    def advance(self, seconds):
        self.assertGreaterEqual(seconds, 0)
        self.now += seconds

    def post(self, url, **kwargs):
        self.assertEqual(url, gateway.neuraldeep_endpoint)
        self.starts.append(self.now)
        self.payloads.append(kwargs['json'])
        if self.replies:
            return self.replies.pop(0)
        return httpx.Response(200, json={'data': [
            {'index': i, 'embedding': [1] * 2560}
            for i in range(len(kwargs['json']['input']))]})

    def test_all_2161_vectors_are_paced_including_recovered_429(self):
        total = 0
        for start in range(0, 2161, 8):
            if start == 400:
                self.replies.append(httpx.Response(429, headers={'Retry-After': '1'},
                    text='NOT_A_REAL_TOKEN private source'))
            batch = [f'document {i}' for i in range(start, min(start + 8, 2161))]
            actual = gateway.neuraldeep_embeddings(batch)
            self.assertEqual(len(actual), len(batch))
            total += len(actual)
        self.assertEqual(total, 2161)
        self.assertEqual(len(self.starts), 272)  # 271 batches + one rejected attempt.
        self.assertTrue(all(b-a >= 2.5 for a, b in zip(self.starts, self.starts[1:])))
        self.assertTrue(all(sum(t <= other < t + 60 for other in self.starts) <= 24
                            for t in self.starts))
        self.assertEqual(self.payloads[50], self.payloads[51])

    def test_retry_after_seconds_date_and_backoff_are_respected(self):
        for header, expected in [('17', 17), (formatdate(1_800_000_023, usegmt=True), 23),
                                 ('invalid NOT_A_REAL_TOKEN', 5), ('0', 5)]:
            with self.subTest(header=header):
                gateway.neuraldeep_next_request_at = 0
                self.starts.clear()
                self.replies.append(httpx.Response(429, headers={'Retry-After': header}))
                gateway.neuraldeep_embeddings(['same immutable batch'])
                self.assertEqual(self.starts[1] - self.starts[0], expected)

    def test_permanent_rate_limit_stops_after_four_attempts_and_redacts(self):
        self.replies = [httpx.Response(429, text='NOT_A_REAL_TOKEN private source')] * 4
        with self.assertRaises(HTTPException) as raised:
            gateway.neuraldeep_embeddings(['private source'])
        self.assertEqual(raised.exception.detail,
                         {'code': 'neuraldeep_embedding_http_error', 'status': 429})
        self.assertEqual(self.starts, [1000, 1005, 1015, 1035])
        self.assertNotIn('NOT_A_REAL_TOKEN', str(raised.exception))
        self.assertNotIn('private source', str(raised.exception))

    def test_long_retry_after_fails_without_shortening_or_more_requests(self):
        for header in ('121', '9' * 128):
            with self.subTest(header=header):
                gateway.neuraldeep_next_request_at = 0
                self.starts.clear()
                self.replies.append(httpx.Response(429, headers={'Retry-After': header}))
                with self.assertRaises(HTTPException) as raised:
                    gateway.neuraldeep_embeddings(['text'])
                self.assertEqual(raised.exception.detail['status'], 429)
                self.assertEqual(len(self.starts), 1)

    def test_retry_budget_includes_time_spent_in_requests(self):
        original = self.post
        def slow_post(*args, **kwargs):
            result = original(*args, **kwargs)
            self.advance(50)
            return result
        self.transport.__enter__.return_value.post.side_effect = slow_post
        self.replies = [httpx.Response(429)] * 4
        with self.assertRaises(HTTPException):
            gateway.neuraldeep_embeddings(['text'])
        self.assertEqual(self.starts, [1000, 1055, 1115])

    def test_auth_payment_and_other_errors_are_not_retried(self):
        for status in (301, 401, 402, 403, 500, 503):
            with self.subTest(status=status):
                before = len(self.starts)
                self.replies.append(httpx.Response(status, text='NOT_A_REAL_TOKEN'))
                with self.assertRaises(HTTPException) as raised:
                    gateway.neuraldeep_embeddings(['text'])
                self.assertEqual(raised.exception.detail['status'], status)
                self.assertEqual(len(self.starts), before + 1)

    def test_parallel_callers_share_slots_and_lock_survives_transport_error(self):
        with ThreadPoolExecutor(max_workers=3) as executor:
            results = list(executor.map(gateway.neuraldeep_embeddings, [['a'], ['b'], ['c']]))
        self.assertEqual([len(r) for r in results], [1, 1, 1])
        self.assertEqual(self.starts, [1000, 1002.5, 1005])
        post = self.transport.__enter__.return_value.post
        post.side_effect = httpx.ConnectError('NOT_A_REAL_TOKEN')
        with self.assertRaises(HTTPException):
            gateway.neuraldeep_embeddings(['failed'])
        post.side_effect = self.post
        self.assertEqual(len(gateway.neuraldeep_embeddings(['recovered'])), 1)

    def test_fingerprint_does_not_depend_on_scheduling(self):
        with patch.dict(os.environ, {'RAG_EMBEDDING_BACKEND': 'neuraldeep'}):
            self.assertEqual(gateway.digest(gateway.embedding_config()),
                'd7aea5ce03896050077cddde1e141882f7dfce6a74c960c505dd9a23f7c17297')
        # HTTP headers and private response bytes are not part of any identity.
        self.assertNotIn('NOT_A_REAL_TOKEN', json.dumps(gateway.config))


if __name__ == '__main__':
    unittest.main()
