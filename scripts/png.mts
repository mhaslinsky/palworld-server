#!/usr/bin/env node

/**
 * Minimal PNG writer, so the modpack icon is generated from source at build time
 * rather than checked in as a binary nobody can diff. Thunderstore requires the icon
 * to be exactly 256x256, which `encodePng` cannot enforce; the caller passes the size.
 */

import { deflateSync } from "node:zlib";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let byteValue = 0; byteValue < 256; byteValue++) {
    let remainder = byteValue;
    for (let bit = 0; bit < 8; bit++) {
      remainder =
        remainder & 1 ? 0xedb88320 ^ (remainder >>> 1) : remainder >>> 1;
    }
    table[byteValue] = remainder >>> 0;
  }
  return table;
})();

export function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeAndData = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(typeAndData), 0);
  return Buffer.concat([length, typeAndData, checksum]);
}

/** `rgba` is width * height * 4 bytes, row-major, 8 bits per channel. */
export function encodePng(
  width: number,
  height: number,
  rgba: Buffer,
): Buffer {
  // The PNG specification requires both dimensions to be nonzero, and a zero-by-zero image
  // otherwise satisfies the buffer-length check below with an empty buffer.
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 1 ||
    height < 1
  ) {
    throw new Error(
      `dimensions must be positive integers, got ${width}x${height}`,
    );
  }
  const expected = width * height * 4;
  if (rgba.length !== expected) {
    throw new Error(
      `pixel buffer is ${rgba.length} bytes, expected ${expected} for ${width}x${height}`,
    );
  }

  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 6; // colour type: RGBA
  // bytes 10-12 stay zero: deflate compression, adaptive filtering, no interlace

  // Every scanline carries a leading filter byte; 0 means the row is stored as-is.
  const rowLength = width * 4;
  const raw = Buffer.alloc(height * (rowLength + 1));
  for (let row = 0; row < height; row++) {
    raw[row * (rowLength + 1)] = 0;
    rgba.copy(
      raw,
      row * (rowLength + 1) + 1,
      row * rowLength,
      (row + 1) * rowLength,
    );
  }

  return Buffer.concat([
    PNG_SIGNATURE,
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

export interface Rgb {
  red: number;
  green: number;
  blue: number;
}

function distanceToSegment(
  pointX: number,
  pointY: number,
  startX: number,
  startY: number,
  endX: number,
  endY: number,
): number {
  const deltaX = endX - startX;
  const deltaY = endY - startY;
  const lengthSquared = deltaX * deltaX + deltaY * deltaY;
  const projection =
    lengthSquared === 0
      ? 0
      : Math.max(
          0,
          Math.min(
            1,
            ((pointX - startX) * deltaX + (pointY - startY) * deltaY) /
              lengthSquared,
          ),
        );
  const closestX = startX + projection * deltaX;
  const closestY = startY + projection * deltaY;
  return Math.hypot(pointX - closestX, pointY - closestY);
}

/**
 * The Algiz rune on a dark ground: a vertical stem with two branches. Drawn from
 * stroke geometry so the icon is reproducible and has no binary source asset.
 */
export function renderAlgizIcon(size: number): Buffer {
  const background: Rgb = { red: 27, green: 34, blue: 40 };
  const foreground: Rgb = { red: 198, green: 154, blue: 88 };
  const unit = size / 256;
  const strokeRadius = 11 * unit;
  const borderInset = 12 * unit;
  const borderWidth = 5 * unit;

  const strokes: [number, number, number, number][] = [
    [128, 44, 128, 214],
    [128, 118, 66, 56],
    [128, 118, 190, 56],
  ].map(
    ([startX, startY, endX, endY]) =>
      [startX * unit, startY * unit, endX * unit, endY * unit] as [
        number,
        number,
        number,
        number,
      ],
  );

  const pixels = Buffer.alloc(size * size * 4);
  for (let row = 0; row < size; row++) {
    for (let column = 0; column < size; column++) {
      const centreX = column + 0.5;
      const centreY = row + 0.5;

      const onBorder =
        centreX >= borderInset &&
        centreY >= borderInset &&
        centreX <= size - borderInset &&
        centreY <= size - borderInset &&
        (centreX <= borderInset + borderWidth ||
          centreY <= borderInset + borderWidth ||
          centreX >= size - borderInset - borderWidth ||
          centreY >= size - borderInset - borderWidth);

      const onRune = strokes.some(
        ([startX, startY, endX, endY]) =>
          distanceToSegment(centreX, centreY, startX, startY, endX, endY) <=
          strokeRadius,
      );

      const colour = onBorder || onRune ? foreground : background;
      const offset = (row * size + column) * 4;
      pixels[offset] = colour.red;
      pixels[offset + 1] = colour.green;
      pixels[offset + 2] = colour.blue;
      pixels[offset + 3] = 255;
    }
  }
  return pixels;
}
