require 'ldap'
require 'net/ldap'
require 'slf4r'

module Ldap
  class Connection < LDAP::Conn

    attr_reader :base, :host, :port

    def initialize(config)
      super(config[:host], config[:port])
      @base = config[:base]
      @port = config[:port]
      @host = config[:host]
      set_option(LDAP::LDAP_OPT_PROTOCOL_VERSION, 3)
    end
    
  end

  class LdapFacade
    
    # @param config Hash for the ldap connection
    def self.open(config)
      ldap2 = Connection.new(config)
      ldap2.bind(config[:auth][:username], config[:auth][:password]) do |ldap|
        yield ldap
      end
    end
    
    include ::Slf4r::Logger

    # @param config Hash for the ldap connection
    def initialize(config)
      if config.is_a? Hash
        @ldap2 = Connection.new(config)
        @ldap2.bind(config[:auth][:username], config[:auth][:password])
      else
        @ldap2 = config
      end
    end

    def retrieve_next_id(treebase, key_field)
      max = 0
      @ldap2.search("#{treebase},#{@ldap2.base}", 
                    LDAP::LDAP_SCOPE_SUBTREE, 
                    "(objectclass=*)", 
                     [key_field]) do |entry|
        n = (entry.vals(key_field) || [0]).first.to_i
        max = n if max < n
      end
      max + 1
    end

    # @param dn_prefix String the prefix of the dn
    # @param treebase the treebase of the dn or any search
    # @param key_field field which carries the integer unique id of the entity
    # @param props Hash of the ldap attributes of the new ldap object
    # @return nil in case of an error or the new id of the created object
    def create_object(dn_prefix, treebase, key_field, props, silence = false)
      base = "#{treebase},#{@ldap2.base}"
      mods = props.collect do |k,v|
        LDAP.mod(LDAP::LDAP_MOD_ADD, k.to_s, v.is_a?(Array) ? v : [v.to_s] )
      end
      if @ldap2.add( dn(dn_prefix, treebase), mods)
#                    :attributes => props) and @ldap.get_operation_result.code.to_s == "0"
        props[key_field.downcase.to_sym]
      else
        unless silence
          msg = ldap_error("create", 
                             dn(dn_prefix, treebase)) + "\n\t#{props.inspect}"
          # TODO maybe raise always an error
          if @ldap2.get_operation_result.code.to_s == "68"
            raise ::DataMapper::PersistenceError.new(msg)
          else
            logger.warn(msg)
          end
        end
        nil
      end
    end

    # @param treebase the treebase of the search
    # @param key_fields Array of fields which carries the integer unique id(s) of the entity
    # @param Array of conditions for the search
    # @return Array of Hashes with a name/values pair for each attribute
    def read_objects(treebase, key_fields, conditions, field_names, order_field = '')
      filters = []
      conditions.each do |cond|
        c = cond[2]
        case cond[0]
        when :or_operator
          f = nil
          cond[1].each do |cc|
            ff = case cc[0]
                 when :eql
                   Net::LDAP::Filter.eq( cc[1].to_s, cc[2].to_s )
                 when :gte
                   f = Net::LDAP::Filter.ge( cc[1].to_s, cc[2].to_s )
                 when :lte
                   f = Net::LDAP::Filter.le( cc[1].to_s, cc[2].to_s )
                 when :like
                   f = Net::LDAP::Filter.eq( cc[1].to_s, cc[2].to_s.gsub(/%/, "*").gsub(/_/, "*").gsub(/\*\*/, "*") )
                 else
                   logger.error(cc[0].to_s + " needs coding")
                 end
            if f
              f = f | ff
            else
              f = ff
            end
          end
        when :eql
          if c.nil?
            f = ~ Net::LDAP::Filter.pres( cond[1].to_s )
          elsif c.class == Array
            f = nil
            c.each do |cc|
              if f
                f = f | Net::LDAP::Filter.eq( cond[1].to_s, cc.to_s )
              else
                f = Net::LDAP::Filter.eq( cond[1].to_s, cc.to_s )
              end
            end
            #elsif c.class == Range
            #  p c
            #  f = Net::LDAP::Filter.ge( cond[1].to_s, c.begin.to_s ) & Net::LDAP::Filter.le( cond[1].to_s, c.end.to_s )
          else
            f = Net::LDAP::Filter.eq( cond[1].to_s, c.to_s )
          end
        when :gte
          f = Net::LDAP::Filter.ge( cond[1].to_s, c.to_s )
        when :lte
          f = Net::LDAP::Filter.le( cond[1].to_s, c.to_s )
        when :not
            if c.nil?
              f = Net::LDAP::Filter.pres( cond[1].to_s )
            elsif c.class == Array
              f = nil
              c.each do |cc|
              if f
                f = f | Net::LDAP::Filter.eq( cond[1].to_s, cc.to_s )
              else
                f = Net::LDAP::Filter.eq( cond[1].to_s, cc.to_s )
              end
            end
              f = ~ f
            else
              f = ~ Net::LDAP::Filter.eq( cond[1].to_s, c.to_s )
            end
        when :like
          f = Net::LDAP::Filter.eq( cond[1].to_s, c.to_s.gsub(/%/, "*").gsub(/_/, "*").gsub(/\*\*/, "*") )
        else
          logger.error(cond[0].to_s + " needs coding")
        end
        filters << f if f
      end
      
      filter = nil
      filters.each do |f|
        if filter.nil?
          filter = f
        else
          filter = filter & f
        end
      end
      logger.debug { "search filter: (#{filter.to_s})" }
      result = []
      begin
      @ldap2.search("#{treebase},#{@ldap2.base}", 
                    LDAP::LDAP_SCOPE_SUBTREE, 
                    filter.to_s == "" ? "(objectclass=*)" : filter.to_s.gsub(/\(\(/, "(").gsub(/\)\)/, ")"), 
                    field_names, false, 0, 0, order_field) do |res|

        map = to_map(res) 
        #puts map[key_field.to_sym]
        # TODO maybe make filter which removes this unless
        # TODO move this into the ldap_Adapter to make it more general, so that
        # all field with Integer gets converted, etc
        result << map if key_fields.select do |key_field|
          if map.member? key_field.to_sym
            # convert field to integer
            map[key_field.to_sym] = [map[key_field.to_sym].collect { |k| k.to_i != 0 ? k.to_s : k }].flatten
            true
          end
        end.size > 0 # i.e. there was at least one key_field in the map
        end
      rescue RuntimeError => e
        raise e unless e.message == "no result returned by search"
      end
      result
    end


    # @param dn_prefix String the prefix of the dn
    # @param treebase the treebase of the dn or any search
    # @param actions the add/replace/delete actions on the attributes
    # @return nil in case of an error or true
    def update_object(dn_prefix, treebase, actions)
      mods = actions.collect do |act|
        mod_op = case act[0]
              when :add
                LDAP::LDAP_MOD_ADD
              when :replace
                LDAP::LDAP_MOD_REPLACE
              when :delete
                LDAP::LDAP_MOD_DELETE
              end
        LDAP.mod(mod_op, act[1].to_s, act[2] == [] ? [] : [act[2].to_s])
      end
      if @ldap2.modify( dn(dn_prefix, treebase), 
                       mods )
        true
      else
        logger.warn(ldap_error("update", 
                               dn(dn_prefix, treebase) + "\n\t#{actions.inspect}"))
        nil
      end
    end

    # @param dn_prefix String the prefix of the dn
    # @param treebase the treebase of the dn or any search
    # @return nil in case of an error or true
    def delete_object(dn_prefix, treebase)
      if @ldap2.delete( dn(dn_prefix, treebase) )
        true
      else
        logger.warn(ldap_error("delete", 
                               dn(dn_prefix, treebase)))
        
        nil
      end
    end

    
    # @param dn String for identifying the ldap object
    # @param password String to be used for authenticate to the dn
    def authenticate(dn, password)
      Net::LDAP.new( { :host => @ldap2.host, 
                       :port => @ldap2.port, 
                       :auth => { 
                         :method => :simple, 
                         :username => dn, 
                         :password => password 
                       }, 
                       :base => @ldap2.base
                     } ).bind
    end

    # helper to concat the dn from the various parts
    # @param dn_prefix String the prefix of the dn
    # @param treebase the treebase of the dn or any search
    # @return the complete dn String
    def dn(dn_prefix, treebase)
      "#{dn_prefix},#{treebase},#{@ldap2.base}"
    end

    private
    
    # helper to extract the Hash from the ldap search result
    # @param Entry from the ldap_search
    # @return Hash with name/value pairs of the entry
    def to_map(entry)
      map = {}
      LDAP::entry2hash(entry).each do |k,v|
        map[k.downcase.to_sym] = v
      end
      map
    end
    
    def ldap_error(method, dn)
      "#{method} error: (#{@ldap2.get_operation_result.code}) #{@ldap2.get_operation_result.message}\n\tDN: #{dn}"
    end
  end
end
