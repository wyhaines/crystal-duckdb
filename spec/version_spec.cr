require "./spec_helper"
require "yaml"

describe DuckDB::VERSION do
  it "matches the shard version" do
    shard = YAML.parse(File.read(File.expand_path("../shard.yml", __DIR__)))
    DuckDB::VERSION.should eq(shard["version"].as_s)
  end
end
