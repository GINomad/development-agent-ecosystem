function createDashboardApi(initialToken) {
  let token = initialToken;
  let sessionRefresh = null;
  return async function api(path, options = {}) {
    const requestToken = token;
    const request = () => fetch(path, {
      ...options,
      headers: { 'Content-Type': 'application/json', 'X-Ecosystem-Token': token, ...(options.headers || {}) }
    });
    let response = await request();
    let body = await response.json();
    if (response.status === 403 && body.error === 'Invalid dashboard session token.' && (options.method || 'GET').toUpperCase() === 'GET') {
      if (token === requestToken) {
        if (!sessionRefresh) {
          sessionRefresh = (async () => {
            const page = await fetch('/', { cache: 'no-store' });
            if (!page.ok) throw new Error(`Unable to refresh dashboard session: HTTP ${page.status}`);
            const pageDocument = new DOMParser().parseFromString(await page.text(), 'text/html');
            const refreshedToken = pageDocument.documentElement.dataset.sessionToken;
            if (!refreshedToken || refreshedToken === '__SESSION_TOKEN__') throw new Error('Unable to refresh dashboard session. Reload the page.');
            token = refreshedToken;
          })().finally(() => { sessionRefresh = null; });
        }
        await sessionRefresh;
      }
      response = await request();
      body = await response.json();
    }
    if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
    return body;
  };
}
