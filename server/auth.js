// Session-based authentication module
import session from 'express-session';
import bcrypt from 'bcryptjs';

const AUTH_USERNAME = process.env.AUTH_USERNAME || 'admin';
const AUTH_PASSWORD_HASH = process.env.AUTH_PASSWORD_HASH;
const SESSION_SECRET = process.env.SESSION_SECRET || 'dev-secret-change-in-production';

export function createSessionMiddleware() {
  return session({
    secret: SESSION_SECRET,
    name: 'sid',
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'lax',
      maxAge: 24 * 60 * 60 * 1000, // 24h
    },
  });
}

// Whitelist paths that don't require authentication
const PUBLIC_PATHS = ['/auth/', '/health', '/assets/'];

export function authGuard(req, res, next) {
  // Allow public paths
  for (const p of PUBLIC_PATHS) {
    if (req.path.startsWith(p) || req.path === '/health') {
      return next();
    }
  }

  // Check session
  if (req.session && req.session.authenticated) {
    return next();
  }

  // For API requests, return 401 JSON
  if (req.path.startsWith('/api/')) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  // For page requests, serve index.html (SPA will show login)
  return next();
}

export async function verifyPassword(plaintext) {
  // Read dynamically so password changes via /auth/change-password take effect immediately
  const hash = process.env.AUTH_PASSWORD_HASH;
  if (!hash) {
    console.error('AUTH_PASSWORD_HASH not configured');
    return false;
  }
  return bcrypt.compare(plaintext, hash);
}

export { AUTH_USERNAME };
