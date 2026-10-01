# frozen_string_literal: true
require_relative "spec_helper"

describe "column_encryption plugin" do
  def have_matching_search(ds, obj)
    ds.sql.gsub("\\_", "_").include?("'#{obj[:enc][0, 48]}%'")
  end

  before do
    @db = Sequel.mock(:numrows=>1)
    @model = Class.new(Sequel::Model)
    @model.set_dataset @db[:ce_test]
    @model.columns :id, :not_enc, :enc
    @model.plugin :column_encryption do |enc|
      enc.key 0, "0"*32

      enc.column :enc
    end
    @obj = @model.new(:not_enc=>'123', :enc=>'Abc')
    @obj.valid?
    @db.fetch = {:id=>1, :not_enc=>'123', :enc=>@obj[:enc]}
    @obj.save
    @db.sqls
  end

  it "should store columns encrypted" do
    @obj.not_enc.must_equal '123'
    @obj[:not_enc].must_equal '123'
    @obj.enc.must_equal 'Abc'
    @obj[:enc].start_with?('AAAA').must_equal true
  end

  it "should support searching encrypted columns" do
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true
    end
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal false
    @obj.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal false
  end

  it "should support case insensitive searching encrypted columns" do
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>:case_insensitive
    end
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal false
    @obj.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'Abd'), @obj).must_equal false
  end

  it "should support searching columns encrypted with previous keys" do
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true
    end
    @obj.reencrypt
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true do |cenc|
        cenc.key 1, "1"*32
        cenc.key 0, "0"*32
      end
    end
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal false
    @obj[:enc].start_with?('AQAA').must_equal true

    @obj.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal false
    @obj.enc.must_equal 'Abc'
    @obj[:enc].start_with?('AQAB').must_equal true
  end

  it "should support case insensitive searching columns encrypted with previous keys" do
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>:case_insensitive
    end
    @obj.reencrypt
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>:case_insensitive do |cenc|
        cenc.key 1, "1"*32
        cenc.key 0, "0"*32
      end
    end
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal true
    @obj[:enc].start_with?('AgAA').must_equal true

    @obj.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal true
    @obj.enc.must_equal 'Abc'
    @obj[:enc].start_with?('AgAB').must_equal true

    have_matching_search(@model.with_encrypted_value(:enc, 'Abd'), @obj).must_equal false
  end

  it "should support searching columns encrypted with previous keys and different case sensitivity setting" do
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true
    end
    @obj.reencrypt
    obj2 = @model.new(:not_enc=>'234', :enc=>'Def')
    obj2.valid?
    def obj2.save(*) end

    @model.plugin :column_encryption do |enc|
      enc.key 1, "1"*32
      enc.key 0, "0"*32

      enc.column :enc, :searchable=>:case_insensitive
    end
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal false
    have_matching_search(@model.with_encrypted_value(:enc, 'Def'), obj2).must_equal false

    @model.plugin :column_encryption do |enc|
      enc.key 2, "2"*32
      enc.key 1, "1"*32
      enc.key 0, "0"*32

      enc.column :enc, :searchable=>:case_insensitive, :search_both=>true
    end
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal false
    have_matching_search(@model.with_encrypted_value(:enc, 'Def'), obj2).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'def'), obj2).must_equal false

    @obj.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal true
    @obj[:enc].start_with?('AgAC').must_equal true

    have_matching_search(@model.with_encrypted_value(:enc, 'Def'), obj2).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'def'), obj2).must_equal false
    obj2.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Def'), obj2).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'def'), obj2).must_equal true
    obj2[:enc].start_with?('AgAC').must_equal true

    @model.plugin :column_encryption do |enc|
      enc.key 3, "3"*32
      enc.key 2, "2"*32
      enc.key 1, "1"*32
      enc.key 0, "0"*32

      enc.column :enc, :searchable=>true, :search_both=>true
    end

    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal true

    @obj.reencrypt
    have_matching_search(@model.with_encrypted_value(:enc, 'Abc'), @obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'abc'), @obj).must_equal false
    @obj[:enc].start_with?('AQAD').must_equal true

    have_matching_search(@model.with_encrypted_value(:enc, 'Abd'), @obj).must_equal false
  end

  it "should keep existing column encryption keys when reloading the plugin without keys" do
    @model.plugin(:column_encryption) do |enc|
      enc.column :enc
    end
    @obj.deserialized_values.clear
    @obj.enc.must_equal "Abc"
  end

  it "should clear existing column encryption keys when reloading the plugin with keys" do
    @model.plugin(:column_encryption) do |enc|
      enc.key 1, "1"*32
      enc.column :enc
    end
    @obj.deserialized_values.clear
    proc{@obj.enc}.must_raise Sequel::Error
  end

  it "should not affect existing column encryption keys when reloading the plugin with keys" do
    @model.plugin(:column_encryption) do |enc|
      enc.key 1, "1"*32
      enc.column :not_enc
    end
    @obj.deserialized_values.clear
    @obj.enc.must_equal "Abc"
  end

  it "should raise an error when trying to decrypt with missing key" do
    @model.plugin :column_encryption do |enc|
      enc.key 1, "1"*32
      enc.column :enc, :searchable=>true
    end
    obj = @model.first
    proc{obj.enc}.must_raise Sequel::Error
  end

  it "should raise an error when trying to decrypt without any keys set" do
    @model = Class.new(Sequel::Model)
    @model.set_dataset @db[:ce_test]
    @model.columns :id, :not_enc, :enc
    proc do
      @model.plugin :column_encryption do |enc|
        enc.column :enc
      end
    end.must_raise Sequel::Error
  end

  it "should raise an error when trying to decrypt with invalid key" do
    @model.plugin :column_encryption do |enc|
      enc.key 0, "1"*32
      enc.column :enc, :searchable=>true
    end
    obj = @model.first
    proc{obj.enc}.must_raise 
  end

  it "should raise an error when trying to decrypt with invalid auth data" do
    @model.plugin :column_encryption do |enc|
      enc.key 0, "0"*32, :auth_data=>'Foo'
      enc.column :enc, :searchable=>true
    end
    obj = @model.first
    proc{obj.enc}.must_raise Sequel::Error
    obj = @model.new(:enc=>"Abc")

    obj.valid?
    obj.deserialized_values.clear
    obj.enc.must_equal "Abc"
  end

  it "should support a configurable amount of padding" do
    @model.plugin :column_encryption do |enc|
      enc.key 1, "0"*32, :padding=>110
      enc.key 0, "0"*32
      enc.column :enc
    end
    encrypt_len = @obj[:enc].bytesize
    @obj.reencrypt
    @obj[:enc].bytesize.must_be(:>, encrypt_len + 100)
  end

  it "should support not using padding" do
    @model.plugin :column_encryption do |enc|
      enc.key 1, "0"*32, :padding=>false
      enc.key 0, "0"*32
      enc.column :enc
    end
    encrypt_len = @obj[:enc].bytesize
    @obj.reencrypt
    @obj[:enc].bytesize.must_be(:<, encrypt_len)
  end

  it "should support reencrypting rows that need reencryption" do
    obj = @model.new(:not_enc=>'234', :enc=>'Def')
    obj.valid?
    def obj.save(*); end

    need_reencrypt = lambda do
      sql = @model.needing_reencryption.sql
      [@obj, obj].count{|o| !(sql.include?("< '#{o[:enc][0, 4]}'") && sql.include?("> '#{o[:enc][0, 4]}B'")) }
    end

    need_reencrypt.call.must_equal 0

    @model.plugin :column_encryption do |enc|
      enc.key 1, "1"*32
      enc.key 0, "0"*32
      enc.column :enc
    end

    need_reencrypt.call.must_equal 2
    @obj.reencrypt
    need_reencrypt.call.must_equal 1
    obj.reencrypt
    need_reencrypt.call.must_equal 0

    @model.plugin :column_encryption do |enc|
      enc.key 1, "1"*32
      enc.column :enc
    end

    need_reencrypt.call.must_equal 0

    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true
    end

    need_reencrypt.call.must_equal 2
    @obj.reencrypt
    need_reencrypt.call.must_equal 1
    obj.reencrypt
    need_reencrypt.call.must_equal 0

    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>:case_insensitive
    end

    need_reencrypt.call.must_equal 2
    @obj.reencrypt
    need_reencrypt.call.must_equal 1
    obj.reencrypt
    need_reencrypt.call.must_equal 0
  end

  it "should not support searching encrypted columns not marked searchable" do
    proc{@model.with_encrypted_value(:enc, 'Abc')}.must_raise Sequel::Error
  end

  it "should not allow column encryption configuration with empty keys" do
    proc do 
      @model.plugin :column_encryption do |enc|
        enc.column(:enc){}
      end
    end.must_raise Sequel::Error
  end

  it "should not allow column encryption configuration with invalid :searchable option" do
    proc do 
      @model.plugin :column_encryption do |enc|
        enc.column(:enc, :searchable=>Object.new)
      end
    end.must_raise Sequel::Error
  end

  it "should require key ids are integers between 0 and 255" do
    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key Object.new, "1"*32
      end
    end.must_raise Sequel::Error

    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key(-1, "1"*32)
      end
    end.must_raise Sequel::Error

    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 256, "1"*32
      end
    end.must_raise Sequel::Error
  end

  it "should require keys are strings with 32 bytes" do
    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 0, Object.new
      end
    end.must_raise Sequel::Error

    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 0, "1"*31
      end
    end.must_raise Sequel::Error

    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 0, "1"*33
      end
    end.must_raise Sequel::Error
  end

  it "should require padding is integer between 1 and 120" do
    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 1, "1"*32, :padding=>Object.new
      end
    end.must_raise Sequel::Error

    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 1, "1"*32, :padding=>0
      end
    end.must_raise Sequel::Error

    proc do 
      @model.plugin :column_encryption do |enc|
        enc.key 1, "1"*32, :padding=>121
      end
    end.must_raise Sequel::Error
  end

  it "should handle empty data" do
    @obj.enc = ''
    @obj.valid?
    @obj.enc.must_equal ''
    @obj[:enc].start_with?('AAAA').must_equal true
  end

  it "should check for errors during decryption" do
    @obj.deserialized_values.clear
    enc = @obj[:enc].dup

    @obj[:enc] = enc.dup.tap{|x| x[0] = '%'}
    proc{@obj.enc}.must_raise Sequel::Error # invalid base-64

    @obj[:enc] = enc.dup.tap{|x| x[0,4] = "BAAA"} # "\4\0\0" base64
    proc{@obj.enc}.must_raise Sequel::Error # invalid flags

    @obj[:enc] = enc.dup.tap{|x| x[0,4] = "AAEA"} # "\0\1\0" base64
    proc{@obj.enc}.must_raise Sequel::Error # invalid reserved byte

    @obj[:enc] = enc.dup.tap{|x| x[0,4] = "AAAB"} # "\0\0\1" base64
    proc{@obj.enc}.must_raise Sequel::Error # invalid key id

    @obj[:enc] = enc.dup.tap{|x| x[0,4] = "AQAA"} # "\1\0\0" base64
    proc{@obj.enc}.must_raise Sequel::Error # invalid minimum size for searchable

    @obj[:enc] = enc.dup.tap{|x| x.slice!(60, 1000)}
    proc{@obj.enc}.must_raise Sequel::Error # invalid minimum size for nonsearchable

    @obj[:enc] = enc.dup.tap{|x| x[63..-3] = x[63..-3].reverse}
    proc{@obj.enc}.must_raise Sequel::Error # corrupt encrypted data
  end

  it "should work in subclasses" do
    sc = Class.new(@model)
    obj = sc.first
    obj.not_enc.must_equal '123'
    obj[:not_enc].must_equal '123'
    obj.enc.must_equal 'Abc'
    obj[:enc].start_with?('AAAA').must_equal true

    sc.plugin :column_encryption do |enc|
      enc.key 1, "1"*32
      enc.column :not_enc
    end

    obj = sc.new
    obj.not_enc = "123"
    obj.not_enc.must_equal '123'
    obj.valid?
    obj[:not_enc].start_with?('AAAB').must_equal true

    obj = @model.first
    obj.not_enc.must_equal '123'
    obj[:not_enc].must_equal '123'
  end

  it "#reencrypt should save only if it modified a column" do
    @obj.reencrypt.must_be_nil

    @model.plugin :column_encryption do |enc|
      enc.column :not_enc
    end

    obj = @model.new(:not_enc=>'123', :enc=>'Abc')
    obj.valid?
    def obj.save(*) self; end
    obj.reencrypt.must_be_nil

    @model.plugin :column_encryption do |enc|
      enc.column :not_enc do |cenc|
        cenc.key 2, "2"*32
        cenc.key 0, "0"*32
      end
    end

    obj.reencrypt.must_be_same_as obj
    obj[:not_enc].start_with?('AAAC').must_equal true
    obj[:enc].start_with?('AAAA').must_equal true

    @model.plugin :column_encryption do |enc|
      enc.column :enc do |cenc|
        cenc.key 1, "1"*32
        cenc.key 0, "0"*32
      end
    end

    obj.reencrypt.must_be_same_as obj
    obj[:not_enc].start_with?('AAAC').must_equal true
    obj[:enc].start_with?('AAAB').must_equal true

    @model.plugin :column_encryption do |enc|
      enc.key 3, "3"*32
      enc.key 2, "2"*32
      enc.key 1, "1"*32
      enc.key 0, "0"*32

      enc.column :not_enc
      enc.column :enc
    end

    obj.reencrypt.must_be_same_as obj
    obj[:not_enc].start_with?('AAAD').must_equal true
    obj[:enc].start_with?('AAAD').must_equal true

    obj[:enc] = nil
    obj.reencrypt.must_be_nil
  end

  it "should support encrypted columns with a registered serialization format" do
    require 'json'
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true, :format=>:json
    end

    obj = @model.new(:not_enc=>'123', :enc=>{'a'=>1})
    obj.id = 1
    obj.valid?
    @db.fetch = obj.values
    @model[obj.id].enc['a'].must_equal 1
    obj[:enc].start_with?('AQAA').must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>1), obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>2), obj).must_equal false

    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true, :format=>:json do |cenc|
        cenc.key 1, "1"*32
        cenc.key 0, "0"*32
      end
    end

    @model[obj.id].enc['a'].must_equal 1
    obj[:enc].start_with?('AQAA').must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>1), obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>2), obj).must_equal false

    db = @db
    obj.define_singleton_method(:save) do |*|
      valid?
      db.fetch = values
    end
    obj.reencrypt
    @model[obj.id].enc['a'].must_equal 1
    obj[:enc].start_with?('AQAB').must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>1), obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>2), obj).must_equal false
  end

  it "should support encrypted columns with a custom serialization format" do
    require 'json'
    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true, :format=>[:to_json.to_proc, JSON.method(:parse)]
    end

    obj = @model.new(:not_enc=>'123', :enc=>{'a'=>1})
    obj.id = 1
    obj.valid?
    @db.fetch = obj.values
    @model[obj.id].enc['a'].must_equal 1
    obj[:enc].start_with?('AQAA').must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>1), obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>2), obj).must_equal false

    @model.plugin :column_encryption do |enc|
      enc.column :enc, :searchable=>true, :format=>[:to_json.to_proc, JSON.method(:parse)] do |cenc|
        cenc.key 1, "1"*32
        cenc.key 0, "0"*32
      end
    end

    @model[obj.id].enc['a'].must_equal 1
    obj[:enc].start_with?('AQAA').must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>1), obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>2), obj).must_equal false

    db = @db
    obj.define_singleton_method(:save) do |*|
      valid?
      db.fetch = values
    end
    obj.reencrypt
    @model[obj.id].enc['a'].must_equal 1
    obj[:enc].start_with?('AQAB').must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>1), obj).must_equal true
    have_matching_search(@model.with_encrypted_value(:enc, 'a'=>2), obj).must_equal false
  end

  it "should raise an error if trying to use an unregistered serialization format" do
    proc do
      @model.plugin :column_encryption do |enc|
        enc.column :enc, :searchable=>true, :format=>:test_ce
      end
    end.must_raise Sequel::Error
  end

  describe "with :context option" do
    before do
      @db = Sequel.mock(:numrows=>1)
      @model = Class.new(Sequel::Model)
      @model.set_dataset @db[:ce_test]
      @model.columns :id, :tenant_id, :not_enc, :enc
      @model.plugin :column_encryption do |enc|
        enc.key 0, "0"*32

        enc.column :enc, :context=>[:tenant_id]
      end
      @obj = @model.new(:tenant_id=>1, :not_enc=>'123', :enc=>'Abc')
      @obj.valid?
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>@obj[:enc]}
      @obj.save
      @db.sqls
    end

    it "should store columns encrypted in context-bound format and decrypt with matching context" do
      @obj.enc.must_equal 'Abc'
      @obj[:enc].start_with?('AwAA').must_equal true

      obj = @model.first
      obj.enc.must_equal 'Abc'
      obj[:enc].start_with?('AwAA').must_equal true
    end

    it "should not decrypt ciphertext copied to a row with a different context" do
      @db.fetch = {:id=>2, :tenant_id=>2, :not_enc=>'123', :enc=>@obj[:enc]}
      proc{@model.first.enc}.must_raise Sequel::Error
    end

    it "should not decrypt ciphertext copied to a different table" do
      model2 = Class.new(Sequel::Model)
      model2.set_dataset @db[:ce_test2]
      model2.columns :id, :tenant_id, :not_enc, :enc
      model2.plugin :column_encryption do |enc|
        enc.key 0, "0"*32

        enc.column :enc, :context=>[:tenant_id]
      end
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>@obj[:enc]}
      proc{model2.first.enc}.must_raise Sequel::Error
    end

    it "should not decrypt ciphertext copied to a different column" do
      @model.plugin :column_encryption do |enc|
        enc.column :not_enc, :context=>[:tenant_id]
      end
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>@obj[:enc], :enc=>@obj[:enc]}
      obj = @model.first
      proc{obj.not_enc}.must_raise Sequel::Error
      obj.enc.must_equal 'Abc'
    end

    it "should reencrypt when a bound attribute changes without the column being read" do
      obj = @model.first
      old_enc = obj[:enc]
      obj.tenant_id = 2
      obj.save
      obj[:enc].wont_equal old_enc
      obj[:enc].start_with?('AwAA').must_equal true

      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>obj[:enc]}
      @model.first.enc.must_equal 'Abc'
      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>old_enc}
      proc{@model.first.enc}.must_raise Sequel::Error
    end

    it "should include the reencrypted column when saving only changed columns" do
      obj = @model.first
      obj.tenant_id = 2
      obj.save_changes
      sql = @db.sqls.last
      sql.must_include "enc"
      sql.must_include "tenant_id"
    end

    it "should reencrypt cached decrypted values with the new context when a bound attribute changes" do
      obj = @model.first
      obj.enc.must_equal 'Abc'
      obj.tenant_id = 2
      obj.enc.must_equal 'Abc'
      obj.save

      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>obj[:enc]}
      @model.first.enc.must_equal 'Abc'
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>obj[:enc]}
      proc{@model.first.enc}.must_raise Sequel::Error
    end

    it "should decrypt using the ciphertext context after a bound attribute changes, and reencrypt on save" do
      obj = @model.first
      obj.tenant_id = 2
      obj.enc.must_equal 'Abc'
      obj.save

      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>obj[:enc]}
      @model.first.enc.must_equal 'Abc'
    end

    it "should raise an error before issuing SQL when a context attribute is missing" do
      obj = @model.new(:not_enc=>'123', :enc=>'Abc')
      proc{obj.save}.must_raise Sequel::Error
      @db.sqls.must_be_empty

      obj = @model.first
      @db.sqls
      obj.tenant_id = nil
      proc{obj.save}.must_raise Sequel::Error
      @db.sqls.must_be_empty
    end

    it "should not guess automatically generated values for context attributes" do
      @model.plugin :column_encryption do |enc|
        enc.column :not_enc, :context=>[:id]
      end
      obj = @model.new(:tenant_id=>1, :not_enc=>'123')
      proc{obj.valid?}.must_raise Sequel::Error
      @db.sqls.must_be_empty
    end

    it "should remain consistent when a save fails and is retried" do
      obj = @model.new(:tenant_id=>1, :not_enc=>'123', :enc=>'Abc')
      raised = false
      obj.define_singleton_method(:save) do |*|
        unless raised
          raised = true
          valid?
          raise Sequel::DatabaseError, "save failed"
        end
        super()
      end
      proc{obj.save}.must_raise Sequel::DatabaseError
      obj.save.must_equal obj
      obj.enc.must_equal 'Abc'

      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>obj[:enc]}
      @model.first.enc.must_equal 'Abc'
    end

    it "should remain consistent when a bound attribute changes between failed save and retry" do
      obj = @model.first
      obj.tenant_id = 2
      obj.valid?
      enc2 = obj[:enc]
      obj.valid?
      obj[:enc].must_equal enc2

      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>enc2}
      @model.first.enc.must_equal 'Abc'
    end

    it "should support key rotation with context-bound columns" do
      @model.plugin :column_encryption do |enc|
        enc.key 1, "1"*32
        enc.key 0, "0"*32

        enc.column :enc, :context=>[:tenant_id]
      end
      obj = @model.first
      obj.enc.must_equal 'Abc'
      obj.reencrypt
      obj[:enc].start_with?('AwAB').must_equal true

      @model.plugin :column_encryption do |enc|
        enc.key 1, "1"*32

        enc.column :enc, :context=>[:tenant_id]
      end
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>obj[:enc]}
      @model.first.enc.must_equal 'Abc'
      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>obj[:enc]}
      proc{@model.first.enc}.must_raise Sequel::Error
    end

    it "should migrate legacy data with :context_migration and only accept the new context afterwards" do
      @model.plugin :column_encryption do |enc|
        enc.column :enc
      end
      obj = @model.new(:tenant_id=>1, :not_enc=>'123', :enc=>'Abc')
      obj.valid?
      legacy = obj[:enc]
      legacy.start_with?('AAAA').must_equal true

      @model.plugin :column_encryption do |enc|
        enc.column :enc, :context=>[:tenant_id]
      end
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>legacy}
      proc{@model.first.enc}.must_raise Sequel::Error

      @model.plugin :column_encryption do |enc|
        enc.column :enc, :context=>[:tenant_id], :context_migration=>true
      end
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>legacy}
      obj = @model.first
      obj.enc.must_equal 'Abc'
      @model.needing_reencryption.sql.must_include "'AwAA'"
      obj.reencrypt
      obj[:enc].start_with?('AwAA').must_equal true
      migrated = obj[:enc]

      @model.plugin :column_encryption do |enc|
        enc.column :enc, :context=>[:tenant_id]
      end
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>legacy}
      proc{@model.first.enc}.must_raise Sequel::Error
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>migrated}
      @model.first.enc.must_equal 'Abc'
      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>'123', :enc=>migrated}
      proc{@model.first.enc}.must_raise Sequel::Error
    end

    it "should support context-bound columns with a serialization format" do
      require 'json'
      @model.plugin :column_encryption do |enc|
        enc.column :enc, :context=>[:tenant_id], :format=>:json
      end
      obj = @model.new(:tenant_id=>1, :enc=>{'a'=>1})
      obj.valid?
      obj[:enc].start_with?('AwAA').must_equal true

      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>nil, :enc=>obj[:enc]}
      @model.first.enc.must_equal({'a'=>1})
      @db.fetch = {:id=>1, :tenant_id=>2, :not_enc=>nil, :enc=>obj[:enc]}
      proc{@model.first.enc}.must_raise Sequel::Error
    end

    it "should handle nil values" do
      obj = @model.new(:tenant_id=>1, :not_enc=>'123', :enc=>nil)
      obj.valid?
      obj[:enc].must_be_nil
      obj.save.must_equal obj

      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>nil}
      @model.first.enc.must_be_nil
    end

    it "should resnapshot contexts on refresh" do
      obj = @model.first
      obj.tenant_id = 2
      @db.fetch = {:id=>1, :tenant_id=>1, :not_enc=>'123', :enc=>@obj[:enc]}
      obj.refresh
      obj.tenant_id.must_equal 1
      obj.enc.must_equal 'Abc'
    end

    it "should work in subclasses" do
      sc = Class.new(@model)
      obj = sc.first
      obj.enc.must_equal 'Abc'
      obj[:enc].start_with?('AwAA').must_equal true
    end

    it "should work when duping objects" do
      obj = @model.first.dup
      obj.id = nil
      obj.tenant_id = 2
      obj.save
      @db.fetch = {:id=>2, :tenant_id=>2, :not_enc=>'123', :enc=>obj[:enc]}
      @model.first.enc.must_equal 'Abc'
    end

    it "should not support searching context-bound columns" do
      proc{@model.with_encrypted_value(:enc, 'Abc')}.must_raise Sequel::Error
    end

    it "should not allow :context with searchable columns" do
      proc do
        @model.plugin :column_encryption do |enc|
          enc.column :enc, :searchable=>true, :context=>[:tenant_id]
        end
      end.must_raise Sequel::Error
    end

    it "should require :context values are column symbols not including the column itself" do
      proc do
        @model.plugin :column_encryption do |enc|
          enc.column :enc, :context=>['tenant_id']
        end
      end.must_raise Sequel::Error

      proc do
        @model.plugin :column_encryption do |enc|
          enc.column :enc, :context=>[:enc]
        end
      end.must_raise Sequel::Error
    end

    it "should require the :context option when using :context_migration" do
      proc do
        @model.plugin :column_encryption do |enc|
          enc.column :enc, :context_migration=>true
        end
      end.must_raise Sequel::Error
    end

    it "should encode context parts unambiguously" do
      ce = Sequel::Plugins::ColumnEncryption
      ce.encode_context(['ab', 'c']).wont_equal ce.encode_context(['a', 'bc'])
      ce.encode_context(['a', 'b']).wont_equal ce.encode_context(['ab'])
      ce.encode_context(['a']).wont_equal ce.encode_context(['a', ''])
    end
  end
end if RUBY_VERSION >= '2.3' && (begin; require 'sequel/plugins/column_encryption'; true; rescue LoadError; false end)
