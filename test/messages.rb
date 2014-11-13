require_relative '../lib/proxy'

module TestProxy
  TEST_MESSAGES = []
  begin
    raise RuntimeError.new('foo')
  rescue => err
    TEST_MESSAGES << Proxy::ErrorMessage.new(err, [])
  end

  def self.random_message()
    TEST_MESSAGES.sample
  end
end
