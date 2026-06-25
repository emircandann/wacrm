import { NextResponse, type NextRequest } from 'next/server'

const SESSION_COOKIE_NAME = 'wacrm_session'

/**
 * Validate the session cookie against the database via the internal
 * `/api/auth/me` route. Middleware runs on the Edge runtime where the
 * Postgres driver isn't available, so we delegate the DB lookup to a
 * Node route handler and forward the cookie. Returns true when the
 * cookie maps to a live session.
 *
 * The lookup MUST go to an internal loopback address, not the public
 * origin: on container platforms like Railway a fetch to the app's own
 * public hostname can't hairpin back to the same instance, so it fails
 * fast and every request would look unauthenticated. When PORT is set
 * (production / `next start`) we call 127.0.0.1:$PORT directly; locally
 * (`next dev`, no PORT) we fall back to the request origin.
 */
async function isAuthenticated(request: NextRequest): Promise<boolean> {
  const token = request.cookies.get(SESSION_COOKIE_NAME)?.value
  if (!token) return false

  const port = process.env.PORT
  const base = port ? `http://127.0.0.1:${port}` : request.nextUrl.origin

  try {
    const res = await fetch(new URL('/api/auth/me', base), {
      headers: { cookie: `${SESSION_COOKIE_NAME}=${token}` },
      // Don't cache — session state changes per request.
      cache: 'no-store',
    })
    if (!res.ok) return false
    const body = (await res.json()) as { user?: unknown }
    return Boolean(body.user)
  } catch {
    // On a transient error, fail closed for protected routes (handled
    // by the caller treating `false` as "not authenticated").
    return false
  }
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl

  const authed = await isAuthenticated(request)

  // Auth pages — redirect to dashboard (or the pending invite) if the
  // visitor is already signed in.
  if (
    authed &&
    (pathname === '/login' ||
      pathname === '/signup' ||
      pathname === '/forgot-password')
  ) {
    const url = request.nextUrl.clone()
    const inviteToken = request.nextUrl.searchParams.get('invite')
    if (inviteToken && (pathname === '/login' || pathname === '/signup')) {
      url.pathname = `/join/${encodeURIComponent(inviteToken)}`
      url.search = ''
    } else {
      url.pathname = '/dashboard'
      url.search = ''
    }
    return NextResponse.redirect(url)
  }

  // Protected pages — redirect to login if not authenticated.
  const protectedPaths = [
    '/dashboard',
    '/inbox',
    '/contacts',
    '/pipelines',
    '/broadcasts',
    '/automations',
    '/flows',
    '/reports',
    '/settings',
  ]
  if (!authed && protectedPaths.some((p) => pathname.startsWith(p))) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    url.search = ''
    return NextResponse.redirect(url)
  }

  // Authenticated WhatsApp API routes (webhooks excluded).
  if (
    !authed &&
    pathname.startsWith('/api/whatsapp/') &&
    !pathname.includes('/webhook')
  ) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  return NextResponse.next()
}

export const config = {
  matcher: [
    // Exclude static files, images, and /api/auth/* (the middleware calls
    // /api/auth/me internally — matching it would cause infinite recursion).
    '/((?!_next/static|_next/image|favicon.ico|api/auth/|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
