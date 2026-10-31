import { describe, expect, it } from 'vitest';
import { approvedImage } from './artwork';

describe('approvedImage', () => {
  it('keeps HTTPS images on the Cover Art Archive and archive.org', () => {
    expect(approvedImage('https://coverartarchive.org/release/abc/1-250.jpg')).toBe('https://coverartarchive.org/release/abc/1-250.jpg');
    expect(approvedImage('https://ia800.us.archive.org/1/items/x/y.jpg')).toBe('https://ia800.us.archive.org/1/items/x/y.jpg');
  });

  it('refuses other hosts, plain HTTP, look-alike hosts and anything unparsable', () => {
    expect(approvedImage('http://coverartarchive.org/release/abc/1-250.jpg')).toBeNull();
    expect(approvedImage('https://example.com/cover.jpg')).toBeNull();
    expect(approvedImage('https://notarchive.org/cover.jpg')).toBeNull();
    expect(approvedImage('https://coverartarchive.org.example.com/cover.jpg')).toBeNull();
    expect(approvedImage('javascript:alert(1)')).toBeNull();
    expect(approvedImage('not a url')).toBeNull();
    expect(approvedImage(null)).toBeNull();
  });
});
