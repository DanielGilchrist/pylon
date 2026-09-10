# A spec blocks on the work rather than sleeping for it, so an example costs what the work costs.
#
# The stall deadline is only here so a deadlock is reported instead of hanging the run in
# silence. It is far longer than any healthy wait and is never what an example is timed against.
private STALLED = 30.seconds

# Blocks until the next value arrives.
def await(channel : Channel(T), *, for what : String) : T forall T
  select
  when value = channel.receive
    value
  when timeout(STALLED)
    fail("#{what} never arrived before the run stalled")
  end
end

# Blocks until the block is satisfied, asking again on every arrival. For a channel that is only
# a nudge, whose payload is read from somewhere else.
def await(channel : Channel(T), *, for what : String, & : -> Bool) : Nil forall T
  until yield
    await(channel, for: what)
  end
end

# Fails on the first arrival inside the span. Showing that something did not happen is the one
# wait that costs real time, because the only evidence is a span in which it could have.
def never_arrives(channel : Channel(T), *, for what : String, within : Time::Span) : Nil forall T
  select
  when value = channel.receive
    fail("#{what} arrived when nothing should have: #{value.inspect}")
  when timeout(within)
  end
end
