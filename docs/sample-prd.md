# Build a REST API for User Management

A backend service that provides CRUD operations for user accounts, including authentication, role-based access control, and profile management. Built with Node.js and PostgreSQL.

## Database Schema & Migrations

Set up the PostgreSQL database with the following tables:

- `users` table with id, email, password_hash, display_name, role, created_at, updated_at
- `sessions` table with id, user_id, token, expires_at, created_at
- `audit_log` table with id, user_id, action, details, created_at

Create migration scripts for initial schema and seed data.

## Authentication Endpoints

Implement secure authentication:

- [ ] POST /api/auth/register — Create a new user account with email validation
- [ ] POST /api/auth/login — Authenticate user and return JWT token
- [ ] POST /api/auth/logout — Invalidate the current session
- [ ] POST /api/auth/refresh — Refresh an expiring JWT token
- [ ] POST /api/auth/forgot-password — Send password reset email

## User CRUD Endpoints

Core user management API:

- [ ] GET /api/users — List users with pagination and filtering
- [ ] GET /api/users/:id — Get user profile by ID
- [ ] PUT /api/users/:id — Update user profile
- [ ] DELETE /api/users/:id — Soft-delete a user account

## Role-Based Access Control

Implement middleware for authorization:

- [ ] Define roles: admin, manager, user
- [ ] Create authorization middleware that checks JWT claims
- [ ] Protect admin-only routes (user deletion, role assignment)
- [ ] Add rate limiting per role tier

## Input Validation & Error Handling

- [ ] Add request validation schemas using Zod
- [ ] Implement consistent error response format
- [ ] Add request logging and correlation IDs

## Integration Tests

- [ ] Write tests for auth flow (register → login → access protected route)
- [ ] Write tests for CRUD operations
- [ ] Write tests for RBAC enforcement
- [ ] Add CI pipeline configuration
