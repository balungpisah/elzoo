defmodule Elzoo.ConsumerGroupCTest do
  # ELZ-049: database-free copied consumers, group c. Three such modules run concurrently;
  # tests inside one module stay in sequence. See Elzoo.CureConsumerCase.
  use Elzoo.CureConsumerCase, async: true

  Elzoo.CureConsumerCase.consumer_tests(Elzoo.CureConsumerCase.database_free_group(:c),
    timeout: Elzoo.CureConsumerCase.concurrent_timeout()
  )
end
