defmodule Elzoo.ConsumerGroupATest do
  # ELZ-049: database-free copied consumers, group a. Three such modules run concurrently;
  # tests inside one module stay in sequence. See Elzoo.CureConsumerCase.
  use Elzoo.CureConsumerCase, async: true

  Elzoo.CureConsumerCase.consumer_tests(Elzoo.CureConsumerCase.database_free_group(:a),
    timeout: Elzoo.CureConsumerCase.concurrent_timeout()
  )
end
