import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../", import.meta.url));
const read = (rel: string): Buffer => readFileSync(ROOT + rel);

const SHARE_URL = "https://julimbob.com/matrixcode/";
const MAX_CARD_BYTES = 300 * 1024;

const html = read("index.html").toString("utf8");

/** Content of the first <meta> whose property or name attribute equals `key`. */
function meta(key: string): string | undefined {
  for (const [tag] of html.matchAll(/<meta\s[^>]*>/g)) {
    const attribute = (name: string): string | undefined => tag.match(new RegExp(`\\s${name}="([^"]*)"`))?.[1];
    if (attribute("property") === key || attribute("name") === key) return attribute("content");
  }
  return undefined;
}

/** Walk JPEG markers to the start-of-frame segment: dimensions and whether it is progressive (SOF2). */
function jpegFrame(buf: Buffer): { width: number; height: number; progressive: boolean } {
  expect(buf.readUInt16BE(0)).toBe(0xffd8);
  let offset = 2;
  while (offset < buf.length) {
    const marker = buf.readUInt16BE(offset);
    const isStartOfFrame = marker >= 0xffc0 && marker <= 0xffcf && ![0xffc4, 0xffc8, 0xffcc].includes(marker);
    if (isStartOfFrame) {
      return { height: buf.readUInt16BE(offset + 5), width: buf.readUInt16BE(offset + 7), progressive: marker === 0xffc2 };
    }
    offset += 2 + buf.readUInt16BE(offset + 2);
  }
  throw new Error("no JPEG start-of-frame marker");
}

describe("link preview tags", () => {
  it("describes the page as Matrix Code on Julimbob", () => {
    expect(meta("og:type")).toBe("website");
    expect(meta("og:site_name")).toBe("Julimbob");
    expect(meta("og:title")).toBe("Matrix Code");
    expect(meta("og:url")).toBe(SHARE_URL);
    expect(meta("twitter:card")).toBe("summary_large_image");
    expect(meta("description")).toBeTruthy();
    expect(meta("og:description")).toBe(meta("description"));
    expect(meta("og:image:alt")).toBeTruthy();
  });

  it("points og:image at the hosted share card with its real type and size", () => {
    expect(meta("og:image")).toBe(`${SHARE_URL}share-card.jpg`);
    expect(meta("og:image:type")).toBe("image/jpeg");
    const card = jpegFrame(read("public/share-card.jpg"));
    expect({ width: card.width, height: card.height }).toEqual({
      width: Number(meta("og:image:width")),
      height: Number(meta("og:image:height")),
    });
    expect(card).toEqual({ width: 1200, height: 630, progressive: true });
  });

  it("keeps the share card small enough for preview crawlers", () => {
    expect(read("public/share-card.jpg").length).toBeLessThanOrEqual(MAX_CARD_BYTES);
  });
});
