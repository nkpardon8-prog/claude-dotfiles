# Backend Patterns

## Repository Pattern
Separate data access from business logic. Database queries live in repository/data-access functions, not in route handlers or controllers. Services call repositories, controllers/routes call services.

## N+1 Prevention
Never query inside a loop. Use joins, includes, or batch queries. If you need data for N items, fetch it all in one query with an `IN` clause or join, not N individual queries.

## Service Layer
Business logic belongs in service functions, not in API route handlers. Route handlers validate input, call the service, and format the response. Services are reusable across routes.

## Error Handling
Use typed/specific errors, not generic catch-all. Let errors propagate with context. Only catch errors where you can handle them meaningfully. Never silently swallow errors.

## Immutability
Create new objects rather than mutating existing ones. Use spread operators, `Object.assign`, or immutable update patterns. Never mutate function parameters.

## Input Validation
Validate at system boundaries (API endpoints, form submissions, external data). Use schema validation (Zod, Joi, etc.) not manual checks. Trust internal function calls — don't re-validate data that was already validated upstream.
