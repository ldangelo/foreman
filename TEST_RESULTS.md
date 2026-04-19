
> @oftheangels/foreman@0.1.0 test
> npm run test:ci


> @oftheangels/foreman@0.1.0 test:ci
> npm run test:unit && npm run test:integration && npm run test:e2e:smoke && npm run test:e2e:full-run


> @oftheangels/foreman@0.1.0 test:unit
> vitest run -c vitest.unit.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m177 passed[39m[22m[90m (177)[39m
[2m      Tests [22m [1m[32m3032 passed[39m[22m[90m (3032)[39m
[2m   Start at [22m 19:57:41
[2m   Duration [22m 16.59s[2m (transform 4.59s, setup 0ms, import 23.05s, tests 120.74s, environment 8ms)[22m


> @oftheangels/foreman@0.1.0 test:integration
> vitest run -c vitest.integration.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m36 passed[39m[22m[90m (36)[39m
[2m      Tests [22m [1m[32m580 passed[39m[22m[90m (580)[39m
[2m   Start at [22m 19:57:58
[2m   Duration [22m 47.88s[2m (transform 1.56s, setup 0ms, import 4.44s, tests 423.63s, environment 2ms)[22m


> @oftheangels/foreman@0.1.0 test:e2e:smoke
> vitest run -c vitest.e2e.smoke.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m      Tests [22m [1m[32m2 passed[39m[22m[90m (2)[39m
[2m   Start at [22m 19:58:46
[2m   Duration [22m 5.77s[2m (transform 166ms, setup 0ms, import 457ms, tests 5.22s, environment 0ms)[22m


> @oftheangels/foreman@0.1.0 test:e2e:full-run
> vitest run -c vitest.e2e.full-run.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-f375a[39m


[2m Test Files [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m      Tests [22m [1m[32m1 passed[39m[22m[90m (1)[39m
[2m   Start at [22m 19:58:52
[2m   Duration [22m 3.06s[2m (transform 153ms, setup 0ms, import 426ms, tests 2.54s, environment 0ms)[22m

