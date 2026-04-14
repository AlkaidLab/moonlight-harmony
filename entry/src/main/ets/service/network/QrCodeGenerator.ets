/*
 * Pure ArkTS QR Code Generator
 * Based on QR Code specification ISO/IEC 18004
 * Inspired by the qrcode-generator project by Kazuhiko Arase (MIT License)
 *
 * Supports Byte mode encoding, error correction levels L/M/Q/H,
 * and auto version selection (1-40).
 */

import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';

// ─── Error Correction Level ───────────────────────────────────────────────────

export enum ECLevel { L = 0, M = 1, Q = 2, H = 3 }

// ─── Constants ────────────────────────────────────────────────────────────────

// Capacity table: max data bytes for each (version, ecLevel)
// version 1..40, indexed by [version-1][ecLevel]
const DATA_CAPACITY: number[][] = [
  [19,16,13,9],[34,28,22,16],[55,44,34,26],[80,64,48,36],[108,86,62,46],
  [136,108,76,60],[156,124,86,66],[194,154,108,86],[232,182,130,100],[274,216,154,122],
  [324,254,180,140],[370,290,206,158],[428,334,244,180],[461,365,261,197],[523,415,295,223],
  [589,453,325,253],[647,507,367,283],[721,563,397,313],[795,627,445,341],[861,669,485,385],
  [932,714,512,406],[1006,782,568,442],[1094,860,614,464],[1174,914,664,514],[1276,1000,718,538],
  [1370,1062,754,596],[1468,1128,808,628],[1531,1193,871,661],[1631,1267,911,701],[1735,1373,985,745],
  [1843,1455,1033,793],[1955,1541,1115,845],[2071,1631,1171,901],[2191,1725,1231,961],[2306,1812,1286,986],
  [2434,1914,1354,1054],[2566,1992,1426,1096],[2702,2102,1502,1142],[2812,2216,1582,1222],[2956,2334,1666,1276],
];

// Number of error correction blocks: [version-1][ecLevel] → [numBlocks, ecWordsPerBlock]
// Simplified: we store [numBlocks1, dataWords1, numBlocks2, dataWords2, ecWordsPerBlock]
// For brevity, use a function to compute from RS block info
const RS_BLOCK_TABLE: number[][] = [
  // v1
  [1,26,19,0,0,7],[1,26,16,0,0,10],[1,26,13,0,0,13],[1,26,9,0,0,17],
  // v2
  [1,44,34,0,0,10],[1,44,28,0,0,16],[1,44,22,0,0,22],[1,44,16,0,0,28],
  // v3
  [1,70,55,0,0,15],[1,70,44,0,0,26],[2,35,17,0,0,18],[2,35,13,0,0,22],
  // v4
  [1,100,80,0,0,20],[2,50,32,0,0,18],[2,50,24,0,0,26],[4,25,9,0,0,16],
  // v5
  [1,134,108,0,0,26],[2,67,43,0,0,24],[2,33,15,2,34,16,18],[2,33,11,2,34,12,22],
  // v6
  [2,86,68,0,0,18],[4,43,27,0,0,16],[4,43,19,0,0,24],[4,43,15,0,0,28],
  // v7
  [2,98,78,0,0,20],[4,49,31,0,0,18],[2,32,14,4,33,15,18],[4,39,13,1,40,14,26],
  // v8
  [2,121,97,0,0,24],[2,60,38,2,61,39,22],[4,40,18,2,41,19,22],[4,40,14,2,41,15,26],
  // v9
  [2,146,116,0,0,30],[3,58,36,2,59,37,22],[4,36,16,4,37,17,20],[4,36,12,4,37,13,24],
  // v10
  [2,86,68,2,87,69,18],[4,69,43,1,70,44,26],[6,43,19,2,44,20,24],[6,43,15,2,44,16,28],
  // v11
  [4,101,81,0,0,20],[1,80,50,4,81,51,30],[4,50,22,4,51,23,28],[3,36,12,8,37,13,24],
  // v12
  [2,116,92,2,117,93,24],[6,58,36,2,59,37,22],[4,46,20,6,47,21,26],[7,42,14,4,43,15,28],
  // v13
  [4,133,107,0,0,26],[8,59,37,1,60,38,22],[8,44,20,4,45,21,24],[12,33,11,4,34,12,22],
  // v14
  [3,145,115,1,146,116,30],[4,64,40,5,65,41,24],[11,36,16,5,37,17,20],[11,36,12,5,37,13,24],
  // v15
  [5,109,87,1,110,88,22],[5,65,41,5,66,42,24],[5,54,24,7,55,25,30],[11,36,12,7,37,13,24],
  // v16
  [5,122,98,1,123,99,24],[7,73,45,3,74,46,28],[15,43,19,2,44,20,24],[3,45,15,13,46,16,30],
  // v17
  [1,135,107,5,136,108,28],[10,74,46,1,75,47,28],[1,50,22,15,51,23,28],[2,42,14,17,43,15,28],
  // v18
  [5,150,120,1,151,121,30],[9,69,43,4,70,44,26],[17,50,22,1,51,23,28],[2,42,14,19,43,15,28],
  // v19
  [3,141,113,4,142,114,28],[3,70,44,11,71,45,26],[17,47,21,4,48,22,26],[9,39,13,16,40,14,26],
  // v20
  [3,135,107,5,136,108,28],[3,67,41,13,68,42,26],[15,54,24,5,55,25,30],[15,43,15,10,44,16,28],
  // v21
  [4,144,116,4,145,117,28],[17,68,42,0,0,26],[17,50,22,6,51,23,28],[19,46,16,6,47,17,30],
  // v22
  [2,139,111,7,140,112,28],[17,74,46,0,0,28],[7,54,24,16,55,25,30],[34,37,13,0,0,24],
  // v23
  [4,151,121,5,152,122,30],[4,75,47,14,76,48,28],[11,54,24,14,55,25,30],[16,45,15,14,46,16,30],
  // v24
  [6,147,117,4,148,118,30],[6,73,45,14,74,46,28],[11,54,24,16,55,25,30],[30,46,16,2,47,17,30],
  // v25
  [8,132,106,4,133,107,26],[8,75,47,13,76,48,28],[7,54,24,22,55,25,30],[22,45,15,13,46,16,30],
  // v26
  [10,142,114,2,143,115,28],[19,74,46,4,75,47,28],[28,50,22,6,51,23,28],[33,46,16,4,47,17,30],
  // v27
  [8,152,122,4,153,123,30],[22,73,45,3,74,46,28],[8,53,23,26,54,24,30],[12,45,15,28,46,16,30],
  // v28
  [3,147,117,10,148,118,30],[3,73,45,23,74,46,28],[4,54,24,31,55,25,30],[11,45,15,31,46,16,30],
  // v29
  [7,146,116,7,147,117,30],[21,73,45,7,74,46,28],[1,53,23,37,54,24,30],[19,45,15,26,46,16,30],
  // v30
  [5,145,115,10,146,116,30],[19,75,47,10,76,48,28],[15,54,24,25,55,25,30],[23,45,15,25,46,16,30],
  // v31
  [13,145,115,3,146,116,30],[2,74,46,29,75,47,28],[42,54,24,1,55,25,30],[23,45,15,28,46,16,30],
  // v32
  [17,145,115,0,0,30],[10,74,46,23,75,47,28],[10,54,24,35,55,25,30],[19,45,15,35,46,16,30],
  // v33
  [17,145,115,1,146,116,30],[14,74,46,21,75,47,28],[29,54,24,19,55,25,30],[11,45,15,46,46,16,30],
  // v34
  [13,145,115,6,146,116,30],[14,74,46,23,75,47,28],[44,54,24,7,55,25,30],[59,46,16,1,47,17,30],
  // v35
  [12,151,121,7,152,122,30],[12,75,47,26,76,48,28],[39,54,24,14,55,25,30],[22,45,15,41,46,16,30],
  // v36
  [6,151,121,14,152,122,30],[6,75,47,34,76,48,28],[46,54,24,10,55,25,30],[2,45,15,64,46,16,30],
  // v37
  [17,152,122,4,153,123,30],[29,74,46,14,75,47,28],[49,54,24,10,55,25,30],[24,45,15,46,46,16,30],
  // v38
  [4,152,122,18,153,123,30],[13,74,46,32,75,47,28],[48,54,24,14,55,25,30],[42,45,15,32,46,16,30],
  // v39
  [20,147,117,4,148,118,30],[40,75,47,7,76,48,28],[43,54,24,22,55,25,30],[10,45,15,67,46,16,30],
  // v40
  [19,148,118,6,149,119,30],[18,75,47,31,76,48,28],[34,54,24,34,55,25,30],[20,45,15,61,46,16,30],
];

// Alignment pattern positions for each version (2-40)
const ALIGNMENT_POSITIONS: number[][] = [
  [], // v1 - no alignment
  [6,18],[6,22],[6,26],[6,30],[6,34],
  [6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],
  [6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],
  [6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],[6,28,50,72,94],
  [6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],
  [6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],
  [6,30,56,82,108,134],[6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],
  [6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],
  [6,32,58,84,110,136,162],[6,26,54,82,110,138,166],[6,30,58,86,114,142,170],
];

// Format information strings (15 bits each, for each mask pattern and EC level)
const FORMAT_INFO: number[][] = [
  // L
  [0x77c4,0x72f3,0x7daa,0x789d,0x662f,0x6318,0x6c41,0x6976],
  // M
  [0x5412,0x5125,0x5e7c,0x5b4b,0x45f9,0x40ce,0x4f97,0x4aa0],
  // Q
  [0x355f,0x3068,0x3f31,0x3a06,0x24b4,0x2183,0x2eda,0x2bed],
  // H
  [0x1689,0x13be,0x1ce7,0x19d0,0x0762,0x0255,0x0d0c,0x083b],
];

// Version information for versions 7-40 (18 bits each)
const VERSION_INFO: number[] = [
  0x07c94,0x085bc,0x09a99,0x0a4d3,0x0bbf6,0x0c762,0x0d847,0x0e60d,
  0x0f928,0x10b78,0x1145d,0x12a17,0x13532,0x149a6,0x15683,0x168c9,
  0x177ec,0x18ec4,0x191e1,0x1afab,0x1b08e,0x1cc1a,0x1d33f,0x1ed75,
  0x1f250,0x209d5,0x216f0,0x228ba,0x2379f,0x24b0b,0x2542e,0x26a64,
  0x27541,0x28c69,
];

// ─── GF(2^8) Arithmetic for Reed-Solomon ──────────────────────────────────────

const GF_EXP: number[] = new Array(512);
const GF_LOG: number[] = new Array(256);

function initGaloisField(): void {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x >= 256) x ^= 0x11d; // primitive polynomial for GF(2^8)
  }
  for (let i = 255; i < 512; i++) {
    GF_EXP[i] = GF_EXP[i - 255];
  }
  GF_LOG[0] = 0; // undefined but set to 0 for convenience
}
initGaloisField();

function gfMul(a: number, b: number): number {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

// ─── Reed-Solomon ─────────────────────────────────────────────────────────────

function rsGeneratorPoly(nsym: number): number[] {
  const g: number[] = new Array(nsym + 1).fill(0);
  g[0] = 1;
  for (let i = 0; i < nsym; i++) {
    for (let j = nsym; j > 0; j--) {
      g[j] = g[j] ^ gfMul(g[j - 1], GF_EXP[i]);
    }
  }
  return g;
}

function rsEncode(data: number[], nsym: number): number[] {
  const gen = rsGeneratorPoly(nsym);
  const out: number[] = new Array(nsym).fill(0);
  for (let i = 0; i < data.length; i++) {
    const coeff = data[i] ^ out[0];
    out.shift();
    out.push(0);
    if (coeff !== 0) {
      for (let j = 0; j < nsym; j++) {
        out[j] ^= gfMul(gen[nsym - j], coeff);
      }
    }
  }
  return out;
}

// ─── Data Encoding (Byte Mode) ────────────────────────────────────────────────

function selectVersion(dataLen: number, ecLevel: ECLevel): number {
  for (let v = 1; v <= 40; v++) {
    const capacity = DATA_CAPACITY[v - 1][ecLevel];
    // Byte mode: 4 bits mode indicator + character count indicator + data
    const ccBits = v <= 9 ? 8 : 16;
    const overhead = Math.ceil((4 + ccBits) / 8);
    if (dataLen + overhead <= capacity) return v;
  }
  return 40; // fallback
}

function encodeData(data: Uint8Array, version: number, ecLevel: ECLevel): number[] {
  const capacity = DATA_CAPACITY[version - 1][ecLevel];
  const ccBits = version <= 9 ? 8 : 16;

  // Build bit stream
  const bits: number[] = [];
  const pushBits = (value: number, len: number): void => {
    for (let i = len - 1; i >= 0; i--) {
      bits.push((value >> i) & 1);
    }
  };

  // Mode indicator: 0100 (byte mode)
  pushBits(0b0100, 4);
  // Character count
  pushBits(data.length, ccBits);
  // Data
  for (let i = 0; i < data.length; i++) {
    pushBits(data[i], 8);
  }
  // Terminator (up to 4 zeros)
  const totalBits = capacity * 8;
  const termLen = Math.min(4, totalBits - bits.length);
  pushBits(0, termLen);
  // Pad to byte boundary
  while (bits.length % 8 !== 0) bits.push(0);
  // Pad bytes
  const padBytes = [0xEC, 0x11];
  let padIdx = 0;
  while (bits.length < totalBits) {
    pushBits(padBytes[padIdx % 2], 8);
    padIdx++;
  }

  // Convert to bytes
  const bytes: number[] = [];
  for (let i = 0; i < bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | (bits[i + j] ?? 0);
    bytes.push(b);
  }
  return bytes;
}

// ─── RS Blocks & Interleaving ─────────────────────────────────────────────────

interface RSBlock {
  totalWords: number;
  dataWords: number;
}

function getRSBlocks(version: number, ecLevel: ECLevel): RSBlock[] {
  const idx = (version - 1) * 4 + ecLevel;
  const row = RS_BLOCK_TABLE[idx];
  const blocks: RSBlock[] = [];
  const count1 = row[0];
  const total1 = row[1];
  const data1 = row[2];
  const count2 = row[3];
  const total2 = row[4];
  const data2 = row[5];
  for (let i = 0; i < count1; i++) blocks.push({ totalWords: total1, dataWords: data1 });
  if (count2 > 0) {
    for (let i = 0; i < count2; i++) blocks.push({ totalWords: total2, dataWords: data2 });
  }
  return blocks;
}

function createCodewords(dataBytes: number[], version: number, ecLevel: ECLevel): number[] {
  const rsBlocks = getRSBlocks(version, ecLevel);
  const dcData: number[][] = [];
  const ecData: number[][] = [];
  let offset = 0;

  for (const block of rsBlocks) {
    const ecWords = block.totalWords - block.dataWords;
    const dc = dataBytes.slice(offset, offset + block.dataWords);
    offset += block.dataWords;
    const ec = rsEncode(dc, ecWords);
    dcData.push(dc);
    ecData.push(ec);
  }

  // Interleave data codewords
  const result: number[] = [];
  const maxDc = Math.max(...dcData.map((d: number[]) => d.length));
  for (let i = 0; i < maxDc; i++) {
    for (const dc of dcData) {
      if (i < dc.length) result.push(dc[i]);
    }
  }
  // Interleave EC codewords
  const maxEc = Math.max(...ecData.map((e: number[]) => e.length));
  for (let i = 0; i < maxEc; i++) {
    for (const ec of ecData) {
      if (i < ec.length) result.push(ec[i]);
    }
  }
  return result;
}

// ─── QR Matrix Construction ───────────────────────────────────────────────────

class QRMatrix {
  readonly size: number;
  readonly modules: boolean[][];      // black=true, white=false
  readonly reserved: boolean[][];     // true if cell is reserved (function pattern)

  constructor(version: number) {
    this.size = version * 4 + 17;
    this.modules = [];
    this.reserved = [];
    for (let i = 0; i < this.size; i++) {
      this.modules.push(new Array(this.size).fill(false));
      this.reserved.push(new Array(this.size).fill(false));
    }
  }

  // Place finder patterns (3 corners)
  placeFinderPatterns(): void {
    const place = (row: number, col: number): void => {
      for (let r = -1; r <= 7; r++) {
        for (let c = -1; c <= 7; c++) {
          const rr = row + r;
          const cc = col + c;
          if (rr < 0 || rr >= this.size || cc < 0 || cc >= this.size) continue;
          const isBlack = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                          (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
                          (r >= 2 && r <= 4 && c >= 2 && c <= 4);
          this.modules[rr][cc] = isBlack;
          this.reserved[rr][cc] = true;
        }
      }
    };
    place(0, 0);
    place(0, this.size - 7);
    place(this.size - 7, 0);
  }

  // Place alignment patterns
  placeAlignmentPatterns(version: number): void {
    if (version < 2) return;
    const positions = ALIGNMENT_POSITIONS[version - 1];
    for (const row of positions) {
      for (const col of positions) {
        // Skip if overlapping with finder patterns
        if (row <= 8 && col <= 8) continue;
        if (row <= 8 && col >= this.size - 8) continue;
        if (row >= this.size - 8 && col <= 8) continue;
        for (let r = -2; r <= 2; r++) {
          for (let c = -2; c <= 2; c++) {
            const isBlack = Math.abs(r) === 2 || Math.abs(c) === 2 || (r === 0 && c === 0);
            this.modules[row + r][col + c] = isBlack;
            this.reserved[row + r][col + c] = true;
          }
        }
      }
    }
  }

  // Place timing patterns
  placeTimingPatterns(): void {
    for (let i = 8; i < this.size - 8; i++) {
      if (!this.reserved[6][i]) {
        this.modules[6][i] = i % 2 === 0;
        this.reserved[6][i] = true;
      }
      if (!this.reserved[i][6]) {
        this.modules[i][6] = i % 2 === 0;
        this.reserved[i][6] = true;
      }
    }
  }

  // Reserve format info areas
  reserveFormatAreas(): void {
    // Around top-left finder
    for (let i = 0; i < 9; i++) {
      if (!this.reserved[8][i]) this.reserved[8][i] = true;
      if (!this.reserved[i][8]) this.reserved[i][8] = true;
    }
    // Around top-right finder
    for (let i = 0; i < 8; i++) {
      if (!this.reserved[8][this.size - 1 - i]) this.reserved[8][this.size - 1 - i] = true;
    }
    // Around bottom-left finder
    for (let i = 0; i < 7; i++) {
      if (!this.reserved[this.size - 1 - i][8]) this.reserved[this.size - 1 - i][8] = true;
    }
    // Dark module
    this.modules[this.size - 8][8] = true;
    this.reserved[this.size - 8][8] = true;
  }

  // Reserve version info areas (v7+)
  reserveVersionAreas(version: number): void {
    if (version < 7) return;
    for (let i = 0; i < 6; i++) {
      for (let j = 0; j < 3; j++) {
        this.reserved[i][this.size - 11 + j] = true;
        this.reserved[this.size - 11 + j][i] = true;
      }
    }
  }

  // Place data bits with mask
  placeDataBits(codewords: number[], maskPattern: number): void {
    let bitIdx = 0;
    const totalBits = codewords.length * 8;
    let col = this.size - 1;

    while (col > 0) {
      if (col === 6) col--; // skip timing column
      for (let row = 0; row < this.size; row++) {
        for (let c = 0; c < 2; c++) {
          const cc = col - c;
          // Direction: upward for even columns from right, downward for odd
          const isUpward = ((this.size - 1 - col) >> 1) % 2 === 0;
          const rr = isUpward ? this.size - 1 - row : row;

          if (this.reserved[rr][cc]) continue;

          let bit = false;
          if (bitIdx < totalBits) {
            bit = ((codewords[bitIdx >> 3] >> (7 - (bitIdx & 7))) & 1) === 1;
            bitIdx++;
          }

          // Apply mask
          if (this.getMask(maskPattern, rr, cc)) bit = !bit;
          this.modules[rr][cc] = bit;
        }
      }
      col -= 2;
    }
  }

  // Write format info
  writeFormatInfo(ecLevel: ECLevel, maskPattern: number): void {
    const info = FORMAT_INFO[ecLevel][maskPattern];
    // Horizontal (row 8)
    for (let i = 0; i < 8; i++) {
      const col = i < 6 ? i : i + 1;
      this.modules[8][col] = ((info >> (14 - i)) & 1) === 1;
    }
    for (let i = 8; i < 15; i++) {
      this.modules[8][this.size - 15 + i] = ((info >> (14 - i)) & 1) === 1;
    }
    // Vertical (col 8)
    for (let i = 0; i < 7; i++) {
      this.modules[this.size - 1 - i][8] = ((info >> (14 - i)) & 1) === 1;
    }
    for (let i = 7; i < 15; i++) {
      const row = i === 7 ? 8 : 14 - i;
      this.modules[row][8] = ((info >> (14 - i)) & 1) === 1;
    }
  }

  // Write version info (v7+)
  writeVersionInfo(version: number): void {
    if (version < 7) return;
    const info = VERSION_INFO[version - 7];
    for (let i = 0; i < 18; i++) {
      const bit = ((info >> i) & 1) === 1;
      const row = Math.floor(i / 3);
      const col = this.size - 11 + (i % 3);
      this.modules[row][col] = bit;
      this.modules[col][row] = bit;
    }
  }

  // Mask pattern evaluation
  private getMask(pattern: number, row: number, col: number): boolean {
    switch (pattern) {
      case 0: return (row + col) % 2 === 0;
      case 1: return row % 2 === 0;
      case 2: return col % 3 === 0;
      case 3: return (row + col) % 3 === 0;
      case 4: return (Math.floor(row / 2) + Math.floor(col / 3)) % 2 === 0;
      case 5: return (row * col) % 2 + (row * col) % 3 === 0;
      case 6: return ((row * col) % 2 + (row * col) % 3) % 2 === 0;
      case 7: return ((row + col) % 2 + (row * col) % 3) % 2 === 0;
      default: return false;
    }
  }

  // Calculate penalty score for mask selection
  penalty(): number {
    let score = 0;
    const n = this.size;

    // Rule 1: Adjacent same-color modules in row/column (5+ = 3 + extra)
    for (let i = 0; i < n; i++) {
      let rowRun = 1;
      let colRun = 1;
      for (let j = 1; j < n; j++) {
        // Row
        if (this.modules[i][j] === this.modules[i][j - 1]) {
          rowRun++;
        } else {
          if (rowRun >= 5) score += 3 + (rowRun - 5);
          rowRun = 1;
        }
        // Column
        if (this.modules[j][i] === this.modules[j - 1][i]) {
          colRun++;
        } else {
          if (colRun >= 5) score += 3 + (colRun - 5);
          colRun = 1;
        }
      }
      if (rowRun >= 5) score += 3 + (rowRun - 5);
      if (colRun >= 5) score += 3 + (colRun - 5);
    }

    // Rule 2: 2x2 blocks of same color
    for (let i = 0; i < n - 1; i++) {
      for (let j = 0; j < n - 1; j++) {
        const v = this.modules[i][j];
        if (v === this.modules[i][j + 1] &&
          v === this.modules[i + 1][j] &&
          v === this.modules[i + 1][j + 1]) {
          score += 3;
        }
      }
    }

    // Rule 3: Finder-like patterns
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n - 6; j++) {
        // Check row
        if (j + 10 < n) {
          if (this.modules[i][j] && !this.modules[i][j+1] && this.modules[i][j+2] &&
            this.modules[i][j+3] && this.modules[i][j+4] && !this.modules[i][j+5] &&
            this.modules[i][j+6]) {
            // Check 4 white on either side
            if (j >= 4 && !this.modules[i][j-1] && !this.modules[i][j-2] &&
              !this.modules[i][j-3] && !this.modules[i][j-4]) score += 40;
            if (j + 10 < n && !this.modules[i][j+7] && !this.modules[i][j+8] &&
              !this.modules[i][j+9] && !this.modules[i][j+10]) score += 40;
          }
        }
        // Check column
        if (j + 10 < n) {
          if (this.modules[j][i] && !this.modules[j+1][i] && this.modules[j+2][i] &&
            this.modules[j+3][i] && this.modules[j+4][i] && !this.modules[j+5][i] &&
            this.modules[j+6][i]) {
            if (j >= 4 && !this.modules[j-1][i] && !this.modules[j-2][i] &&
              !this.modules[j-3][i] && !this.modules[j-4][i]) score += 40;
            if (j + 10 < n && !this.modules[j+7][i] && !this.modules[j+8][i] &&
              !this.modules[j+9][i] && !this.modules[j+10][i]) score += 40;
          }
        }
      }
    }

    // Rule 4: Proportion of dark modules
    let dark = 0;
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        if (this.modules[i][j]) dark++;
      }
    }
    const total = n * n;
    const pct = (dark * 100) / total;
    const prev5 = Math.floor(pct / 5) * 5;
    const next5 = prev5 + 5;
    score += Math.min(Math.abs(prev5 - 50) / 5, Math.abs(next5 - 50) / 5) * 10;

    return score;
  }
}

// ─── Main Generation ──────────────────────────────────────────────────────────

function buildQR(data: Uint8Array, ecLevel: ECLevel): QRMatrix {
  const version = selectVersion(data.length, ecLevel);
  const dataBytes = encodeData(data, version, ecLevel);
  const codewords = createCodewords(dataBytes, version, ecLevel);

  // Try all 8 mask patterns, pick the one with lowest penalty
  let bestMask = 0;
  let bestScore = Infinity;
  let bestMatrix: QRMatrix | null = null;

  for (let mask = 0; mask < 8; mask++) {
    const m = new QRMatrix(version);
    m.placeFinderPatterns();
    m.placeAlignmentPatterns(version);
    m.placeTimingPatterns();
    m.reserveFormatAreas();
    m.reserveVersionAreas(version);
    m.placeDataBits(codewords, mask);
    m.writeFormatInfo(ecLevel, mask);
    m.writeVersionInfo(version);

    const score = m.penalty();
    if (score < bestScore) {
      bestScore = score;
      bestMask = mask;
      bestMatrix = m;
    }
  }

  return bestMatrix!;
}

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Generate a QR code as a boolean matrix
 * @param content String to encode (UTF-8)
 * @param ecLevel Error correction level (default: M)
 * @returns 2D boolean array (true = black module)
 */
export function generateQrMatrix(content: string, ecLevel: ECLevel = ECLevel.M): boolean[][] {
  const encoder = new util.TextEncoder();
  const data = encoder.encodeInto(content);
  return buildQR(new Uint8Array(data), ecLevel).modules;
}

/**
 * Generate a QR code as a PixelMap image
 * @param content String to encode (UTF-8)
 * @param size Output image size in pixels
 * @param ecLevel Error correction level (default: M)
 * @param quietZone Quiet zone modules (default: 2)
 * @returns PixelMap of the QR code
 */
export async function generateQrPixelMap(
  content: string,
  size: number = 600,
  ecLevel: ECLevel = ECLevel.M,
  quietZone: number = 2
): Promise<image.PixelMap> {
  const modules = generateQrMatrix(content, ecLevel);
  const moduleCount = modules.length;
  const totalModules = moduleCount + quietZone * 2;
  const scale = Math.floor(size / totalModules);
  const imgSize = scale * totalModules;

  // Create RGBA buffer
  const pixels = new ArrayBuffer(imgSize * imgSize * 4);
  const view = new Uint8Array(pixels);

  // Fill white background
  view.fill(255);

  // Draw black modules
  for (let row = 0; row < moduleCount; row++) {
    for (let col = 0; col < moduleCount; col++) {
      if (modules[row][col]) {
        const px = (col + quietZone) * scale;
        const py = (row + quietZone) * scale;
        for (let dy = 0; dy < scale; dy++) {
          for (let dx = 0; dx < scale; dx++) {
            const offset = ((py + dy) * imgSize + (px + dx)) * 4;
            view[offset] = 0;     // R
            view[offset + 1] = 0; // G
            view[offset + 2] = 0; // B
            // A stays 255
          }
        }
      }
    }
  }

  const createOpts: image.InitializationOptions = {
    size: { height: imgSize, width: imgSize },
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false,
  };
  return image.createPixelMap(pixels, createOpts);
}
