
> @oftheangels/foreman@0.1.0 test
> npm run test:ci


> @oftheangels/foreman@0.1.0 test:ci
> npm run test:unit && npm run test:integration && npm run test:e2e:smoke && npm run test:e2e:full-run


> @oftheangels/foreman@0.1.0 test:unit
> vitest run -c vitest.unit.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m177 passed[39m[22m[90m (177)[39m
[2m      Tests [22m [1m[32m3032 passed[39m[22m[90m (3032)[39m
[2m   Start at [22m 19:55:23
[2m   Duration [22m 19.46s[2m (transform 2.02s, setup 0ms, import 20.54s, tests 173.71s, environment 8ms)[22m


> @oftheangels/foreman@0.1.0 test:integration
> vitest run -c vitest.integration.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m36 passed[39m[22m[90m (36)[39m
[2m      Tests [22m [1m[32m580 passed[39m[22m[90m (580)[39m
[2m   Start at [22m 19:55:43
[2m   Duration [22m 47.73s[2m (transform 1.23s, setup 0ms, import 3.55s, tests 425.30s, environment 2ms)[22m


> @oftheangels/foreman@0.1.0 test:e2e:smoke
> vitest run -c vitest.e2e.smoke.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m      Tests [22m [1m[32m2 passed[39m[22m[90m (2)[39m
[2m   Start at [22m 19:56:31
[2m   Duration [22m 5.69s[2m (transform 184ms, setup 0ms, import 471ms, tests 5.13s, environment 0ms)[22m


> @oftheangels/foreman@0.1.0 test:e2e:full-run
> vitest run -c vitest.e2e.full-run.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m      Tests [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m   Start at [22m 19:56:37
[2m   Duration [22m 3.04s[2m (transform 154ms, setup 0ms, import 425ms, tests 2.52s, environment 0ms)[22m

