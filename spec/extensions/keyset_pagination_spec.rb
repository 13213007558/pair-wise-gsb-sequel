# frozen_string_literal: true
require_relative "spec_helper"

describe "keyset_pagination" do
  def make_cursor(payload)
    [JSON.generate(payload)].pack('m0').tr('+/', '-_').sub(/=+\z/, '')
  end

  def decode_cursor(cursor)
    str = cursor.to_s.tr('-_', '+/')
    JSON.parse("#{str}#{'=' * ((4 - str.length % 4) % 4)}".unpack1('m0')
  end

  before do
    @db = Sequel
  end
end
