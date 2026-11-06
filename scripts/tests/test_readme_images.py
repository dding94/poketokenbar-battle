import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
READMES = ["README.md", "README.ja.md"]
EMBED = re.compile(r'<img[^>]*\ssrc="([^"]+)"|!\[[^\]]*\]\(([^)\s]+)')


def local_embeds(readme):
    text = (ROOT / readme).read_text(encoding="utf-8")
    for m in EMBED.finditer(text):
        target = m.group(1) or m.group(2)
        if re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue
        yield target.split("?")[0].split("#")[0]


class ReadmeImageTests(unittest.TestCase):
    def test_every_local_embed_exists(self):
        missing = []
        for readme in READMES:
            for target in local_embeds(readme):
                if not (ROOT / target).is_file():
                    missing.append(f"{readme}: {target}")
        self.assertEqual([], missing)


if __name__ == "__main__":
    unittest.main()
