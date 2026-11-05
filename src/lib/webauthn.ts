/**
 * The browser side of passkeys: the server's JSON options go to `navigator.credentials`, the
 * credential comes back as JSON. Uses the browser's own JSON conversions (Chrome 128, Firefox 119,
 * Safari 18.4 and later); without them passkeys are reported as unsupported here.
 */

export class PasskeyUnsupportedError extends Error {
  constructor() {
    super('This browser can’t use passkeys here.');
    this.name = 'PasskeyUnsupportedError';
  }
}

/** The person closed the browser's passkey prompt, or no passkey matched. */
export class PasskeyCancelledError extends Error {
  constructor() {
    super('The passkey prompt was closed.');
    this.name = 'PasskeyCancelledError';
  }
}

export function passkeysSupported(): boolean {
  return typeof PublicKeyCredential !== 'undefined'
    && typeof PublicKeyCredential.parseCreationOptionsFromJSON === 'function'
    && typeof PublicKeyCredential.parseRequestOptionsFromJSON === 'function';
}

function requireSupport(): void {
  if (!passkeysSupported()) throw new PasskeyUnsupportedError();
}

function cancelled(e: unknown): boolean {
  return e instanceof DOMException && (e.name === 'NotAllowedError' || e.name === 'AbortError');
}

type CredentialJSON = ReturnType<PublicKeyCredential['toJSON']>;

export async function createPasskey(options: PublicKeyCredentialCreationOptionsJSON): Promise<CredentialJSON> {
  requireSupport();
  try {
    const credential = await navigator.credentials.create({ publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options) });
    if (!(credential instanceof PublicKeyCredential)) throw new PasskeyCancelledError();
    return credential.toJSON();
  } catch (e) {
    throw cancelled(e) ? new PasskeyCancelledError() : e;
  }
}

export async function getPasskey(options: PublicKeyCredentialRequestOptionsJSON): Promise<CredentialJSON> {
  requireSupport();
  try {
    const credential = await navigator.credentials.get({ publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options) });
    if (!(credential instanceof PublicKeyCredential)) throw new PasskeyCancelledError();
    return credential.toJSON();
  } catch (e) {
    throw cancelled(e) ? new PasskeyCancelledError() : e;
  }
}
