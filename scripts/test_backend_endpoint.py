import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('endpoint', Path(__file__).with_name('validate-backend-endpoint.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EndpointTests(unittest.TestCase):
    def setUp(self):
        # Reserved example.com fixture hosts are never deployed or configured.
        self.endpoints = {key: f'https://{key}.example.com' for key in ('dev', 'staging', 'prod')}

    def test_each_environment_and_all_cross_environment_swaps(self):
        for environment, own in self.endpoints.items():
            module.validate(self.endpoints, environment, own, own)
            for other in self.endpoints.values():
                if other != own:
                    with self.assertRaises(ValueError):
                        module.validate(self.endpoints, environment, other, other)

    def test_mismatched_plist_and_missing_configured_endpoint(self):
        for backend, plist in [('', ''), ('$(BACKEND_BASE_URL)', '$(BACKEND_BASE_URL)'),
                               (self.endpoints['staging'], ''), ('', self.endpoints['staging'])]:
            with self.assertRaises(ValueError):
                module.validate(self.endpoints, 'staging', backend, plist)

    def test_unprovisioned_environment_remains_disabled(self):
        endpoints = dict(self.endpoints, prod='')
        module.validate(endpoints, 'prod', '', '')
        with self.assertRaises(ValueError):
            module.validate(endpoints, 'prod', endpoints['staging'], endpoints['staging'])

    def test_unsafe_manifest_and_shared_environments(self):
        for url in ['http://staging.example.com', 'https://localhost', 'https://127.0.0.1',
                    'https://api.local', 'https://api.invalid', 'https://api.example.com/path',
                    'https://user@api.example.com', 'https://api.example.com?key=value',
                    'https://api.example.com#fragment', 'https://api.example.com:443',
                    'https://api.example.com\n', self.endpoints['prod'], None]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                endpoints = dict(self.endpoints, staging=url)
                module.validate(endpoints, 'staging', url, url)


if __name__ == '__main__':
    unittest.main()
