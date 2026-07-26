using TestShards

# Dogfooded: this suite is itself run through TestShards, so the driver is exercised on
# every CI run rather than only by the unit tests below it.
TestShards.@runtests oneshots = ["test_aqua.jl"]
