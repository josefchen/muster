import index from './index.html';
import privacy from './privacy.html';
import client from './client.js';
import { createSite } from './server.ts';

export default createSite({ index, privacy, client });
