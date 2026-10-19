"""Controlled HTTP responses test the real gateway; no hosted inference here."""
import importlib.util
import contextlib
import io
import json
import math
import os
from pathlib import Path
import unittest
import urllib.error
import urllib.request
from unittest.mock import MagicMock, patch

import httpx
from fastapi import HTTPException
from fastapi.testclient import TestClient

spec = importlib.util.spec_from_file_location(
    'hf_gateway', Path(__file__).parents[3] / 'tool/rag_model_service/app.py')
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class Tokenizer:
    def __call__(self, text, **kwargs):
        return {'input_ids': list(range(len(text)))}


class HfGatewayTest(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {'RAG_EMBEDDING_BACKEND': 'hf-deepinfra',
                                          'HF_TOKEN': 'NOT_A_REAL_TOKEN'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def body(self):
        return gateway.EmbedInput(expected_model_fingerprint=gateway.digest(gateway.embedding_config()),
            inputs=[gateway.EmbedItem(id='document', kind='passage', text='Document'),
                    gateway.EmbedItem(id='question', kind='query', text='Question')])

    def response(self, data, status=200):
        return httpx.Response(status, json=data)

    def run_embeddings(self, response):
        transport = MagicMock()
        transport.__enter__.return_value.post.return_value = response
        with patch.object(gateway.httpx, 'Client', return_value=transport) as client, \
             patch.object(gateway, 'tokenizer', return_value=Tokenizer()):
            result = gateway.embeddings(self.body())
        return result, client, transport.__enter__.return_value.post

    def test_order_query_prompt_normalization_and_fixed_remote_route(self):
        data = {'model': gateway.hf_model, 'data': [
            {'index': 1, 'embedding': [0, 3] + [0] * 1022},
            {'index': 0, 'embedding': [4, 0] + [0] * 1022}]}
        result, client, post = self.run_embeddings(self.response(data))
        self.assertEqual([o['id'] for o in result['outputs']], ['document', 'question'])
        self.assertEqual(result['outputs'][0]['vector'][:2], [1, 0])
        self.assertEqual(result['outputs'][1]['vector'][:2], [0, 1])
        self.assertFalse(result['truncated'])
        args, kwargs = post.call_args
        self.assertEqual(args, (gateway.hf_endpoint,))
        self.assertEqual(kwargs['json'], {'model': gateway.hf_model, 'encoding_format': 'float',
            'input': ['Document', gateway.query_instruction + 'Question']})
        self.assertEqual(kwargs['headers'], {'Authorization': 'Bearer NOT_A_REAL_TOKEN'})
        self.assertFalse(client.call_args.kwargs['trust_env'])
        self.assertFalse(client.call_args.kwargs['follow_redirects'])
        self.assertEqual(post.call_count, 1)
        self.assertNotIn('NOT_A_REAL_TOKEN', json.dumps(result))

    def test_health_has_no_secret_or_ollama_call_and_has_distinct_identity(self):
        with patch.object(gateway, 'tokenizer', return_value=Tokenizer()), \
             patch.object(gateway.httpx, 'Client') as client:
            health = gateway.health()
        client.assert_not_called()
        self.assertEqual(health['embedding']['weights_revision'], 'provider-managed-unpinned')
        self.assertNotEqual(health['fingerprint'], 'df2af910c83efd01d39f7ba4012e24bdc1ba98281ad65efff841fd025148279d')
        self.assertNotIn('NOT_A_REAL_TOKEN', json.dumps(health))

    def test_actual_asgi_routes_return_protocol_and_redacted_provider_failure(self):
        with TestClient(gateway.app) as client, \
             patch.object(gateway, 'tokenizer', return_value=Tokenizer()):
            health = client.get('/health')
            self.assertEqual(health.status_code, 200)
            request = self.body().model_dump()
            transport = MagicMock()
            post = transport.__enter__.return_value.post
            post.return_value = self.response({'data': [
                {'index': 0, 'embedding': [1] * 1024}, {'index': 1, 'embedding': [1] * 1024}]})
            with patch.object(gateway.httpx, 'Client', return_value=transport):
                result = client.post('/v1/embeddings', json=request)
                self.assertEqual(result.status_code, 200)
                self.assertEqual(result.json()['fingerprint'], health.json()['fingerprint'])
                self.assertEqual([r['id'] for r in result.json()['outputs']], ['document', 'question'])
                post.return_value = httpx.Response(402, text='NOT_A_REAL_TOKEN private text')
                failure = client.post('/v1/embeddings', json=request)
                self.assertEqual(failure.status_code, 502)
                self.assertEqual(failure.json(), {'detail': {'code': 'hf_embedding_http_error', 'status': 402}})
                self.assertNotIn('NOT_A_REAL_TOKEN', failure.text)

    def test_upstream_auth_credit_rate_redirect_and_server_errors_are_redacted(self):
        for status in (301, 401, 402, 403, 429, 503):
            with self.subTest(status=status), self.assertRaises(HTTPException) as raised:
                self.run_embeddings(httpx.Response(status, text='NOT_A_REAL_TOKEN private source text'))
            self.assertEqual(raised.exception.detail, {'code': 'hf_embedding_http_error', 'status': status})
            self.assertNotIn('NOT_A_REAL_TOKEN', str(raised.exception))

    def test_bad_model_indices_vectors_json_and_empty_vectors_fail_closed(self):
        good = {'model': gateway.hf_model, 'data': [
            {'index': 0, 'embedding': [1] * 1024}, {'index': 1, 'embedding': [1] * 1024}]}
        bad = [{'model': 'different', 'data': good['data']}, {'data': []},
               {'data': good['data'][:1]}, {'data': [good['data'][0]] * 2},
               {'data': [{'index': True, 'embedding': [1] * 1024}, good['data'][1]]},
               {'data': [{'index': 2, 'embedding': [1] * 1024}, good['data'][1]]},
               {'data': [{'index': 0, 'embedding': [1]}, good['data'][1]]},
               {'data': [{'index': 0, 'embedding': [True] * 1024}, good['data'][1]]},
               {'data': [{'index': 0, 'embedding': [0] * 1024}, good['data'][1]]},
               {'data': [{'index': 0, 'embedding': ['1'] * 1024}, good['data'][1]]},
               []]
        for data in bad:
            with self.subTest(data_type=type(data).__name__), self.assertRaises(HTTPException):
                self.run_embeddings(self.response(data))
        for content in ('invalid-json', '{"data":[{"index":0,"embedding":[NaN]}]}', 'x' * 2_000_001):
            with self.assertRaises(HTTPException):
                self.run_embeddings(httpx.Response(200, content=content))

    def test_fingerprint_input_bounds_and_configuration_fail_before_dispatch(self):
        for change in ('fingerprint', 'kind', 'length'):
            body = self.body()
            if change == 'fingerprint': body.expected_model_fingerprint = 'old-local-index'
            if change == 'kind': body.inputs[0].kind = 'unknown'
            if change == 'length': body.inputs[0].text = 'x' * 8193
            with patch.object(gateway.httpx, 'Client') as client, \
                 patch.object(gateway, 'tokenizer', return_value=Tokenizer()), \
                 self.assertRaises(HTTPException):
                gateway.embeddings(body)
            client.assert_not_called()
        for config in ({'HF_TOKEN': ''}, {'RAG_EMBEDDING_BACKEND': 'unknown'}):
            with patch.dict(os.environ, config), self.assertRaises(HTTPException):
                gateway.embedding_config()

    def test_transport_exception_and_nonfinite_values_do_not_escape(self):
        client = MagicMock()
        client.__enter__.return_value.post.side_effect = httpx.ConnectError('NOT_A_REAL_TOKEN')
        with patch.object(gateway.httpx, 'Client', return_value=client), \
             self.assertRaises(HTTPException) as raised:
            gateway.hf_embeddings(['test'])
        self.assertEqual(raised.exception.detail, 'hf_embedding_connection_failed')
        # Bypass JSON serialization to exercise the numeric validator itself.
        for number in (math.nan, math.inf, 10**400):
            response = MagicMock(status_code=200, content=b'{}')
            response.json.return_value = {'data': [{'index': 0, 'embedding': [number] * 1024}]}
            client.__enter__.return_value.post.side_effect = None
            client.__enter__.return_value.post.return_value = response
            with patch.object(gateway.httpx, 'Client', return_value=client), self.assertRaises(HTTPException):
                gateway.hf_embeddings(['test'])

    def test_default_ollama_backend_retains_original_fingerprint(self):
        transport = MagicMock()
        transport.__enter__.return_value.get.return_value.raise_for_status.return_value.json.return_value = {
            'models': [{'name': gateway.embedding_model,
                        'digest': 'ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d'}]}
        with patch.dict(os.environ, {'RAG_EMBEDDING_BACKEND': 'ollama'}), \
             patch.object(gateway.httpx, 'Client', return_value=transport):
            self.assertEqual(gateway.digest(gateway.embedding_config()),
                'df2af910c83efd01d39f7ba4012e24bdc1ba98281ad65efff841fd025148279d')

    def test_exact_bootstrap_preflight_checks_remote_access_before_corpus(self):
        script = Path('tool/headless/bootstrap_rag_ci.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        health = {'ready': True, 'dimension': 1024, 'fingerprint': 'HF-TEST',
                  'embedding': gateway.embedding_config()}
        probe = {'fingerprint': 'HF-TEST', 'dimension': 1024,
                 'outputs': [{'id': 'startup', 'vector': [1] * 1024}]}
        with patch.object(urllib.request, 'urlopen', side_effect=[
                io.BytesIO(json.dumps(health).encode()), io.BytesIO(json.dumps(probe).encode())]) as request, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            exec(compile(script, 'actual-ci-preflight', 'exec'), {})
        self.assertEqual(request.call_count, 2)
        actual = request.call_args_list[1].args[0]
        self.assertEqual(actual.full_url, 'http://127.0.0.1:8765/v1/embeddings')
        self.assertNotIn('NOT_A_REAL_TOKEN', actual.data.decode())
        self.assertNotIn('Authorization', actual.headers)
        self.assertIn('startup probe passed', output.getvalue())
        error = urllib.error.HTTPError('local', 502, '', {}, io.BytesIO(json.dumps({
            'detail': {'code': 'hf_embedding_http_error', 'status': 403,
                       'body': 'NOT_A_REAL_TOKEN'}}).encode()))
        with patch.object(urllib.request, 'urlopen', side_effect=[io.BytesIO(json.dumps(health).encode()), error]), \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as raised:
            exec(compile(script, 'actual-ci-preflight', 'exec'), {})
        self.assertIn('upstream HTTP 403', str(raised.exception))
        self.assertNotIn('NOT_A_REAL_TOKEN', str(raised.exception))


if __name__ == '__main__':
    unittest.main()
