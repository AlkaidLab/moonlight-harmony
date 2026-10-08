/* SPDX-License-Identifier: GPL-3.0-or-later */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';

export const PIPW_REVIEW_VERSION = 'd83e8223052491180467fb2b7a06443a6286b7cf';
export const PIPW_MAX_BYTES = 20 * 1024 * 1024;
export type PipwPool = 'pc' | 'phone';

interface PipwRecord {
  id: string;
  md5: string;
}

interface PipwRecords {
  pc: PipwRecord[];
  phone: PipwRecord[];
}

class PipwReviewedPool {
  byId: Map<string, string> = new Map();
  byMd5: Map<string, string> = new Map();
}

/** The resource is shared verbatim with moonlight-vplus PR #696. */
export class PipwReviewIndex {
  private pc: PipwReviewedPool = new PipwReviewedPool();
  private phone: PipwReviewedPool = new PipwReviewedPool();

  constructor(json: string) {
    const records = JSON.parse(json) as PipwRecords;
    if (!records || Object.keys(records).sort().join(',') !== 'pc,phone') {
      throw new Error('Invalid Pipw review index');
    }
    this.pc = this.parsePool(records.pc, 'pc');
    this.phone = this.parsePool(records.phone, 'phone');
  }

  private parsePool(records: PipwRecord[], pool: PipwPool): PipwReviewedPool {
    if (!Array.isArray(records) || records.length === 0) {
      throw new Error('Empty Pipw review pool');
    }
    const result = new PipwReviewedPool();
    const filenamePattern = new RegExp(`^image-${pool}-[0-9]+\\.(webp|png|jpg|jpeg|avif|gif|bmp)$`, 'i');
    for (const record of records) {
      if (!record || Object.keys(record).sort().join(',') !== 'id,md5' ||
        typeof record.id !== 'string' || !filenamePattern.test(record.id) ||
        typeof record.md5 !== 'string' || !/^[0-9a-f]{32}$/.test(record.md5) || result.byId.has(record.id)) {
        throw new Error('Invalid Pipw review record');
      }
      result.byId.set(record.id, record.md5);
      const alias = result.byMd5.get(record.md5);
      if (!alias || record.id < alias) {
        result.byMd5.set(record.md5, record.id);
      }
    }
    return result;
  }

  accepts(pool: PipwPool, data: ArrayBuffer): boolean {
    return data.byteLength > 0 && data.byteLength <= PIPW_MAX_BYTES &&
      this.getPool(pool).byMd5.has(PipwReviewIndex.md5(new Uint8Array(data)));
  }

  fallbackNames(pool: PipwPool): string[] {
    return Array.from(this.getPool(pool).byMd5.values());
  }

  private getPool(pool: PipwPool): PipwReviewedPool {
    return pool === 'phone' ? this.phone : this.pc;
  }

  static md5(data: Uint8Array): string {
    const md = cryptoFramework.createMd('MD5');
    md.updateSync({ data: data } as cryptoFramework.DataBlob);
    const digest = md.digestSync().data;
    if (digest.length !== 16) {
      throw new Error('Pipw digest unavailable');
    }
    let hex = '';
    for (const value of digest) {
      hex += value.toString(16).padStart(2, '0');
    }
    return hex;
  }

  static cacheKey(identity: string): string {
    return PipwReviewIndex.md5(new Uint8Array(buffer.from(identity, 'utf-8')));
  }
}
