import { readFileSync, createWriteStream } from "fs";
import { XMLParser } from "fast-xml-parser";
import { PNG } from "pngjs";

function extractImage(xmlText) {
  const parser = new XMLParser({
    ignoreAttributes: false,
    removeNSPrefix: true,
    trimValues: true,
  });

  const doc = parser.parse(xmlText);
  const eposPrint = doc?.Envelope?.Body?.["epos-print"];
  if (!eposPrint) {
    throw new Error("No epos-print element found in XML");
  }

  const imageNode = eposPrint.image;
  if (!imageNode) {
    throw new Error("No image element found in epos-print");
  }

  const image = Array.isArray(imageNode) ? imageNode[0] : imageNode;
  const width = Number(image["@_width"]);
  const height = Number(image["@_height"]);
  const color = image["@_color"] ?? "mono";
  const base64 =
    typeof image === "string"
      ? image
      : typeof image["#text"] === "string"
        ? image["#text"]
        : "";

  if (!Number.isFinite(width) || !Number.isFinite(height)) {
    throw new Error("Image width and height must be numeric");
  }

  if (!base64.trim()) {
    throw new Error("Image element has no base64 data");
  }

  return { width, height, color, base64: base64.replace(/\s+/g, "") };
}

function detectPackingMode(raster, width, height) {
  const byteAlignedCeil = Math.ceil(width / 8) * height;
  const byteAlignedFloor = (width >> 3) * height;
  const continuous = Math.ceil((width * height) / 8);

  if (raster.length === byteAlignedCeil) {
    return "byteAlignedCeil";
  }
  if (raster.length === continuous) {
    return "continuous";
  }
  if (raster.length === byteAlignedFloor) {
    return "byteAlignedFloor";
  }

  const candidates = [
  ["byteAlignedCeil", byteAlignedCeil],
  ["continuous", continuous],
  ["byteAlignedFloor", byteAlignedFloor],
  ];

  candidates.sort(
    (a, b) => Math.abs(raster.length - a[1]) - Math.abs(raster.length - b[1])
  );

  console.warn(
    `Warning: raster size ${raster.length} bytes does not exactly match any packing mode; using closest: ${candidates[0][0]} (expected ${candidates[0][1]} bytes)`
  );

  return candidates[0][0];
}

function decodeEposMonoRaster(base64, width, height) {
  const raster = Buffer.from(base64, "base64");
  const mode = detectPackingMode(raster, width, height);
  const pixels = new Uint8Array(width * height * 4);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let byteIndex;
      let bitPos;

      if (mode === "continuous") {
        const bitIndex = y * width + x;
        byteIndex = bitIndex >> 3;
        bitPos = 7 - (bitIndex & 7);
      } else {
        const bytesPerRow =
          mode === "byteAlignedCeil" ? Math.ceil(width / 8) : width >> 3;
        byteIndex = y * bytesPerRow + (x >> 3);
        bitPos = 7 - (x & 7);
      }

      if (byteIndex >= raster.length) {
        continue;
      }

      const bit = (raster[byteIndex] >> bitPos) & 1;
      const shade = bit ? 0 : 255;
      const offset = (y * width + x) * 4;
      pixels[offset] = shade;
      pixels[offset + 1] = shade;
      pixels[offset + 2] = shade;
      pixels[offset + 3] = 255;
    }
  }

  return { width, height, data: pixels, mode };
}

function writePng({ width, height, data }, outputPath) {
  return new Promise((resolve, reject) => {
    const png = new PNG({ width, height });
    png.data = Buffer.from(data);
    png
      .pack()
      .pipe(createWriteStream(outputPath))
      .on("finish", resolve)
      .on("error", reject);
  });
}

async function main() {
  const inputPath = process.argv[2] ?? "test.xml";
  const outputPath = process.argv[3] ?? "output.png";

  const xmlText = readFileSync(inputPath, "utf8");
  const { width, height, color, base64 } = extractImage(xmlText);

  if (color !== "mono" && color !== undefined) {
    throw new Error(`Unsupported color mode "${color}" (only mono is supported)`);
  }

  const image = decodeEposMonoRaster(base64, width, height);
  await writePng(image, outputPath);

  console.log(
    `Rendered ${width}x${height} image to ${outputPath} (packing: ${image.mode})`
  );
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
