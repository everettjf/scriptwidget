export class StudioAPIError extends Error {
  constructor(message, status, body = {}) {
    super(message);
    this.name = "StudioAPIError";
    this.status = status;
    this.body = body;
  }
}

export class WebStudioAPI {
  constructor({ fetchImpl = globalThis.fetch, token = () => "", onUnauthorized = () => {} } = {}) {
    if (typeof fetchImpl !== "function") throw new TypeError("A fetch implementation is required");
    this.fetchImpl = fetchImpl;
    this.token = token;
    this.onUnauthorized = onUnauthorized;
  }

  async request(path, options = {}) {
    const response = await this.fetchImpl(path, this.authorizedOptions(options));
    const body = await response.json().catch(() => ({}));
    this.validate(response, path, body);
    return body;
  }

  async requestBlob(path, options = {}) {
    const response = await this.fetchImpl(path, this.authorizedOptions(options));
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      this.validate(response, path, body);
    }
    return response.blob();
  }

  authorizedOptions(options) {
    return {
      ...options,
      headers: {
        "Content-Type": "application/json",
        "X-Studio-Token": this.token(),
        ...(options.headers || {}),
      },
    };
  }

  validate(response, path, body) {
    if (!response.ok) {
      const error = new StudioAPIError(body.message || `Request failed (${response.status})`, response.status, body);
      if (response.status === 401 && path !== "/api/v1/pair") this.onUnauthorized(error);
      throw error;
    }
  }
}
