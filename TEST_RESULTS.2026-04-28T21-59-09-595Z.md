
> @oftheangels/foreman@0.1.0 test
> npm run test:ci


> @oftheangels/foreman@0.1.0 test:ci
> npm run test:unit && npm run test:integration && npm run test:e2e:smoke && npm run test:e2e:full-run


> @oftheangels/foreman@0.1.0 test:unit
> vitest run -c vitest.unit.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-630e8[39m


[2m Test Files [22m [1m[32m206 passed[39m[22m[90m (206)[39m
[2m      Tests [22m [1m[32m3544 passed[39m[22m[90m (3544)[39m
[2m   Start at [22m 07:19:20
[2m   Duration [22m 13.04s[2m (transform 7.35s, setup 0ms, import 33.55s, tests 84.54s, environment 12ms)[22m


> @oftheangels/foreman@0.1.0 test:integration
> vitest run -c vitest.integration.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-630e8[39m


[2m Test Files [22m [1m[32m36 passed[39m[22m[90m (36)[39m
[2m      Tests [22m [1m[32m590 passed[39m[22m[90m (590)[39m
[2m   Start at [22m 07:19:34
[2m   Duration [22m 41.28s[2m (transform 2.66s, setup 0ms, import 4.45s, tests 193.83s, environment 2ms)[22m


> @oftheangels/foreman@0.1.0 test:e2e:smoke
> vitest run -c vitest.e2e.smoke.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-630e8[39m


[2m Test Files [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m      Tests [22m [1m[32m2 passed[39m[22m[90m (2)[39m
[2m   Start at [22m 07:20:15
[2m   Duration [22m 4.53s[2m (transform 183ms, setup 0ms, import 472ms, tests 3.97s, environment 0ms)[22m


> @oftheangels/foreman@0.1.0 test:e2e:full-run
> vitest run -c vitest.e2e.full-run.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/.foreman/worktrees/9c825a66-276b-4419-8594-219783b4cf4f/foreman-630e8[39m


[2m Test Files [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m      Tests [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m   Start at [22m 07:20:20
[2m   Duration [22m 2.29s[2m (transform 195ms, setup 0ms, import 489ms, tests 1.71s, environment 0ms)[22m

