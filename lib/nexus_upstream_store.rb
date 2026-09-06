require "yaml"
require "time"

class NexusUpstreamStore
  def initialize(path)
    @path = path
  end

  def records
    with_lock { load }
  end

  def find(id)
    records.find { |r| r["id"] == id }
  end

  def update_record(id, attrs)
    with_lock do
      data = load
      record = data.find { |r| r["id"] == id }
      raise ArgumentError, "no such record: #{id}" unless record

      record.merge!(attrs)
      record["updated_at"] = Time.now.utc
      save(data)
      record
    end
  end

  private

  def with_lock
    File.open(@path, "r+") do |f|
      f.flock(File::LOCK_EX)
      result = yield
      f.flock(File::LOCK_UN)
      result
    end
  end

  def load
    YAML.safe_load_file(@path, permitted_classes: [ Time, Date ], aliases: true) || []
  end

  def save(data)
    File.write(@path, YAML.dump(data))
  end
end
