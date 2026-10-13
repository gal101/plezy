import unittest

from check_staged_privacy import inspect_added_lines


class CheckStagedPrivacyTest(unittest.TestCase):
    def test_flags_private_ip_email_and_user_home(self):
        private_ip = "192." + "168.1.20"
        email = "person@" + "mydomain.com"
        diff = (
            "diff --git a/example.txt b/example.txt\n+++ b/example.txt\n"
            "@@ -0,0 +1,3 @@\n"
            f"+server={private_ip}\n"
            f"+owner={email}\n"
            "+path=C:\\Users\\Andrei\\secret.txt\n"
        )
        findings = inspect_added_lines(diff)
        self.assertEqual(len(findings), 3)
        self.assertTrue(any("private IPv4" in finding for finding in findings))
        self.assertTrue(any("email address" in finding for finding in findings))
        self.assertTrue(any("Windows home path" in finding for finding in findings))

    def test_allows_documentation_values_and_github_noreply(self):
        diff = """diff --git a/example.txt b/example.txt
+++ b/example.txt
@@ -0,0 +1,2 @@
+server=192.0.2.12
+author=123+user@users.noreply.github.com
"""
        self.assertEqual(inspect_added_lines(diff), [])

    def test_flags_high_confidence_tokens(self):
        token = "ghp_" + "123456789012345678901234567890"
        diff = "diff --git a/example.txt b/example.txt\n+++ b/example.txt\n@@ -0,0 +1 @@\n+token=" + token + "\n"
        self.assertTrue(any("credential" in finding for finding in inspect_added_lines(diff)))


if __name__ == "__main__":
    unittest.main()
