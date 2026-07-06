test_tmp = Path.expand("../tmp/test", __DIR__)
File.rm_rf!(test_tmp)
File.mkdir_p!(test_tmp)
System.put_env("FOREMAN_SERVER_EVENT_LOG", Path.join(test_tmp, "events.term.log"))
System.put_env("FOREMAN_SERVER_PROJECT_STORE", Path.join(test_tmp, "projects.term"))

ExUnit.start()
