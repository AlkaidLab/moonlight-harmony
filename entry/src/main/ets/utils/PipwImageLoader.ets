/* SPDX-License-Identifier: GPL-3.0-or-later */
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { url } from '@kit.ArkTS';
import { PipwPool, PipwReviewIndex, PIPW_MAX_BYTES } from './PipwReviewIndex';

const REDIRECTS: number[] = [301, 302, 303, 307, 308];
let temporarySequence: number = 0;

export interface ReviewedImage {
  data: ArrayBuffer;
  extension: string;
}

interface PipwResponse {
  code: number;
  location: string;
  data: ArrayBuffer;
}

export class PipwDownloadOperation {
  cancelled: boolean = false;
  template: string = '';
  initialFilename: string = '';
  private cancelRequest: (() => void) | null = null;

  cancel(): void {
    this.cancelled = true;
    if (this.cancelRequest) {
      this.cancelRequest();
    }
  }

  attach(cancelRequest: (() => void) | null): void {
    this.cancelRequest = cancelRequest;
    if (cancelRequest) this.checkActive();
  }

  checkActive(): void {
    if (this.cancelled) {
      throw new Error('Pipw download cancelled');
    }
  }
}

export class PipwUrlPolicy {
  static isOfficial(value: string): boolean {
    try {
      return new url.URL(value).hostname.toLowerCase() === 'img-api.pipw.top';
    } catch (e) {
      return false;
    }
  }

  static api(value: string, pool: PipwPool): string {
    const parsed = new url.URL(value);
    if (!PipwUrlPolicy.isOfficial(value) || parsed.protocol !== 'https:' || parsed.username ||
      parsed.password || parsed.hash) {
      throw new Error('Invalid Pipw API');
    }
    parsed.params.delete('phone');
    if (pool === 'phone') {
      parsed.params.set('phone', 'true');
    }
    return parsed.toString();
  }

  static candidate(value: string, pool: PipwPool): string {
    const parsed = new url.URL(value);
    const name = decodeURIComponent(parsed.pathname.substring(parsed.pathname.lastIndexOf('/') + 1));
    const stem = name.substring(0, name.lastIndexOf('.'));
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.hash ||
      /%(2f|5c|25|2e)/i.test(parsed.pathname) ||
      stem === '.' || stem === '..' ||
      !/^[^/\\\x00]+\.(webp|png|jpe?g|avif|gif|bmp)$/i.test(name) ||
      name.startsWith(pool === 'phone' ? 'image-pc-' : 'image-phone-')) {
      throw new Error('Invalid Pipw candidate');
    }
    return parsed.toString();
  }

  static redirect(base: string, location: string, pool: PipwPool): string {
    if (!location) {
      throw new Error('Missing Pipw redirect');
    }
    return PipwUrlPolicy.candidate(new url.URL(location, base).toString(), pool);
  }

  static fallback(template: string, filename: string, pool: PipwPool): string {
    const parsed = new url.URL(template);
    parsed.pathname = parsed.pathname.substring(0, parsed.pathname.lastIndexOf('/') + 1) + filename;
    parsed.search = '';
    parsed.hash = '';
    return PipwUrlPolicy.candidate(parsed.toString(), pool);
  }
}

export class PipwImageLoader {
  private index: PipwReviewIndex;
  private directory: string;

  constructor(index: PipwReviewIndex, directory: string) {
    this.index = index;
    this.directory = directory;
  }

  async load(api: string, pool: PipwPool, operation: PipwDownloadOperation): Promise<ReviewedImage> {
    const deadline = Date.now() + 30000;
    const normalized = PipwUrlPolicy.api(api, pool);
    // Seeded before the first request so a rejected or unreachable first
    // response can still fall back to a reviewed filename instead of failing.
    operation.template = normalized;
    // API < 23 has no maxRedirects: NetworkKit follows redirects inside this
    // request, so the initial call already carries the full image body and
    // needs the candidate download budget instead of the redirect-hop budget.
    const legacyNetworkStack = deviceInfo.sdkApiVersion < 23;
    const initialBudgetMs = legacyNetworkStack ? 15000 : 7000;
    let response: PipwResponse;
    try {
      response = await this.request(normalized, Math.min(deadline, Date.now() + initialBudgetMs), operation, pool);
    } catch (e) {
      return await this.fallback(pool, deadline, operation);
    }
    operation.checkActive();
    // Older systems follow redirects inside NetworkKit. Only the final, reviewed bytes are accepted.
    if (response.code === 200) {
      try {
        const result = await this.verify(response.data, pool);
        operation.checkActive();
        if (Date.now() >= deadline) throw new Error('Pipw download timed out');
        return result;
      } catch (e) {
        return await this.fallback(pool, deadline, operation);
      }
    }
    if (!REDIRECTS.includes(response.code)) {
      throw new Error('Pipw API unavailable');
    }
    const initial = PipwUrlPolicy.redirect(normalized, response.location, pool);
    operation.template = initial;
    try {
      return await this.download(initial, pool, deadline, operation);
    } catch (e) {
      return await this.fallback(pool, deadline, operation);
    }
  }

  private async fallback(pool: PipwPool, deadline: number,
    operation: PipwDownloadOperation): Promise<ReviewedImage> {
    operation.checkActive();
    if (!operation.template || Date.now() >= deadline) {
      throw new Error('No reviewed Pipw fallback');
    }
    const template = new url.URL(operation.template);
    const currentName = template.pathname.substring(template.pathname.lastIndexOf('/') + 1);
    const names = this.index.fallbackNames(pool).filter((name: string) =>
      name !== currentName && name !== operation.initialFilename);
    if (names.length === 0) {
      throw new Error('Empty Pipw fallback');
    }
    const filename = names[Math.floor(Math.random() * names.length)];
    return await this.download(PipwUrlPolicy.fallback(operation.template, filename, pool), pool, deadline, operation);
  }

  private async download(initial: string, pool: PipwPool, overallDeadline: number,
    operation: PipwDownloadOperation): Promise<ReviewedImage> {
    const deadline = Math.min(overallDeadline, Date.now() + 15000);
    const visited: Set<string> = new Set();
    let current = initial;
    for (let hop = 0; hop < 3; hop++) {
      operation.checkActive();
      if (visited.has(current)) {
        throw new Error('Pipw redirect loop');
      }
      visited.add(current);
      operation.template = current;
      const response = await this.request(current, deadline, operation, pool);
      if (response.code === 200) {
        const result = await this.verify(response.data, pool);
        operation.checkActive();
        if (Date.now() >= deadline) {
          throw new Error('Pipw candidate timed out');
        }
        return result;
      }
      if (!REDIRECTS.includes(response.code)) {
        throw new Error('Pipw image unavailable');
      }
      current = PipwUrlPolicy.redirect(current, response.location, pool);
    }
    throw new Error('Too many Pipw redirects');
  }

  private async verify(data: ArrayBuffer, pool: PipwPool): Promise<ReviewedImage> {
    if (!this.index.accepts(pool, data)) {
      throw new Error('Pipw content has not been reviewed');
    }
    const extension = PipwImageLoader.extension(data);
    const source = image.createImageSource(data);
    try {
      const info = await source.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        throw new Error('Unsupported Pipw image');
      }
    } finally {
      await source.release();
    }
    return { data: data, extension: extension };
  }

  static extension(data: ArrayBuffer): string {
    const bytes = new Uint8Array(data);
    if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'jpg';
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e &&
      bytes[3] === 0x47 && bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10) return 'png';
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
      bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'webp';
    if (bytes.length >= 6 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38 &&
      (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61) return 'gif';
    if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) return 'bmp';
    if (bytes.length >= 12 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70 &&
      bytes[8] === 0x61 && bytes[9] === 0x76 && bytes[10] === 0x69 && (bytes[11] === 0x66 || bytes[11] === 0x73)) return 'avif';
    throw new Error('Unsupported background image format');
  }

  private request(value: string, deadline: number, operation: PipwDownloadOperation,
    pool: PipwPool): Promise<PipwResponse> {
    operation.checkActive();
    if (Date.now() >= deadline) {
      throw new Error('Pipw download timed out');
    }
    const path = `${this.directory}/pipw-${Date.now()}-${++temporarySequence}.tmp`;
    const request = http.createHttp();
    let file: fileIo.File;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    } catch (e) {
      request.destroy();
      throw e as Error;
    }
    return new Promise<PipwResponse>((resolve, reject) => {
      let finished = false;
      let received = 0;
      let declared = -1;
      let location = '';
      let responseBase = value;
      const timer = setTimeout(() => finish(0, new Error('Pipw download timed out')), deadline - Date.now());
      const finish = (code: number, error: Error | null): void => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        let data = new ArrayBuffer(0);
        try {
          if (!error && code === 200) {
            if (received === 0 || (declared >= 0 && received !== declared)) {
              throw new Error('Incomplete Pipw image');
            }
            data = new ArrayBuffer(received);
            const read = fileIo.readSync(file.fd, data, { offset: 0 });
            if (read !== received) throw new Error('Incomplete Pipw temporary file');
          }
        } catch (e) {
          error = e as Error;
        } finally {
          try { request.destroy(); } catch (e) { error = e as Error; }
          operation.attach(null);
          try { fileIo.closeSync(file.fd); } catch (e) { error = e as Error; }
          try { fileIo.unlinkSync(path); } catch (e) { error = e as Error; }
        }
        if (error) reject(error);
        else resolve({ code: code, location: location, data: data });
      };
      try {
        operation.attach(() => finish(0, new Error('Pipw download cancelled')));
        request.on('headersReceive', (headers: Object) => {
          if (finished) return;
          try {
            // NetworkKit can emit headers for every automatically followed response on API < 23.
            // Only the current response's length and body belong to its final content digest.
            received = 0;
            declared = -1;
            location = '';
            const values = headers as Record<string, string>;
            for (const key of Object.keys(values)) {
              const lower = key.toLowerCase();
              if (lower === 'location') {
                location = values[key];
                responseBase = PipwUrlPolicy.redirect(responseBase, location, pool);
                operation.template = responseBase;
                if (!operation.initialFilename) {
                  const parsed = new url.URL(responseBase);
                  operation.initialFilename = parsed.pathname.substring(parsed.pathname.lastIndexOf('/') + 1);
                }
              } else if (lower === 'content-length') {
                declared = Number(values[key]);
                if (!Number.isFinite(declared) || declared < 0 || declared > PIPW_MAX_BYTES) {
                  throw new Error('Invalid Pipw content length');
                }
              } else if (lower === 'content-encoding' && values[key].toLowerCase() !== 'identity') {
                throw new Error('Unexpected Pipw content encoding');
              }
            }
          } catch (e) {
            finish(0, e as Error);
          }
        });
        request.on('dataReceive', (chunk: ArrayBuffer) => {
          if (finished) return;
          try {
            operation.checkActive();
            if (received + chunk.byteLength > PIPW_MAX_BYTES || Date.now() >= deadline) {
              throw new Error('Pipw image exceeds download limit');
            }
            if (fileIo.writeSync(file.fd, chunk, { offset: received }) !== chunk.byteLength) {
              throw new Error('Incomplete Pipw file write');
            }
            received += chunk.byteLength;
          } catch (e) {
            finish(0, e as Error);
          }
        });
        // Older auto-redirect systems carry the whole image in one request;
        // give them the wider connection/reading windows the old app used.
        const legacyNetworkStack = deviceInfo.sdkApiVersion < 23;
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: { 'Accept-Encoding': 'identity' },
          usingCache: false,
          connectTimeout: legacyNetworkStack ? 5000 : 2000,
          readTimeout: legacyNetworkStack ? 15000 : 5000,
          maxLimit: PIPW_MAX_BYTES
        };
        if (deviceInfo.sdkApiVersion >= 23) options.maxRedirects = 0;
        request.requestInStream(value, options, (error, code) => {
          finish(code, error ? new Error(error.message) : null);
        });
      } catch (e) {
        finish(0, e as Error);
      }
    });
  }
}
