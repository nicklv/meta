# -*- encoding: utf-8 -*-
require 'redis/hash_key'

class Item
  include Mongoid::Document
  include Mongoid::Timestamps::Created

  # Referenced
  embeds_many :timelines, class_name:  'ItemTimeline'
  belongs_to  :seller,    foreign_key: 'seller_nick', index: true

  # Fields
  field :num_iid,     type: Integer
  field :seller_nick, type: String

  field :outer_id,    type: String
  field :title,       type: String
  field :pic_url,     type: String

  field :prom_type,   type: String
  field :status,      type: String,   default: -> {'onsale'}  # 商品状态 [ onsale soldout inventory ]

  field :price,         type: Float,   default: 0
  field :tag_price,     type: Float,   default: -> { price }
  field :prom_price,    type: Float,   default: -> { price }
  field :prom_discount, type: Integer, default: 100

  field :total_num,   type: Integer,  default: 0
  field :month_num,   type: Integer,  default: 0
  field :quantity,    type: Integer,  default: 0

  field :favs_count,  type: Integer,  default: 0
  field :skus_count,  type: Integer,  default: 0
  field :post_fee,    type: Boolean,  default: false

  field :campaign_ids,type: Array,  default: []
  field :category_ids,type: Array,  default: []

  field :timestamp,   type: Integer
  field :_id,         type: Integer,  default: -> { num_iid }

  scope :onsale, where(status: 'onsale')

  default_scope desc(:favs_count)

  def categories
    Category.where(seller_nick: seller_nick).in(_id: category_ids)
  end

  def category_names
    categories.only(:cat_name).distinct(:cat_name)
  end

  def campaigns # 大促
    Campaign.where(seller_nick: seller_nick).in(_id: campaign_ids)
  end

  def campaign_names
    campaigns.only(:name).distinct(:name)
  end

  def item_timeline(new_item)
    timeline  = to_timeline
    increment = item_increment(new_item)
    if increment.nil? # 无差异，讲不形成记录
      nil
    else
      timeline.merge(increment: increment)
    end
  end

  def to_timeline
    # {
    #   outer_id:      outer_id,
    #   title:         title,
    #   pic_url:       pic_url,
    #   prom_type:     prom_type,
    #   price:         price,
    #   prom_price:    prom_price,
    #   prom_discount: prom_discount,
    #   total_num:     total_num,
    #   month_num:     month_num,
    #   quantity:      quantity,
    #   favs_count:    favs_count,
    #   skus_count:    skus_count,
    #   post_fee:      post_fee,
    #   status:        status,
    #   timestamp:     timestamp
    # }
    ActiveSupport::JSON.decode(self.to_json).symbolize_keys
  end

  def item_increment(new_item)
    logger.debug new_item
    new_increment = {
       timestamp: new_item[:timestamp],
      # 小时
        duration: ( (new_item[:timestamp] - timestamp) / 3600.to_f).round(2),
      # 销售
       total_num: new_item[:total_num]  - total_num,
       month_num: new_item[:month_num]  - month_num,
      # 库存
        quantity: new_item[:quantity]   - quantity,
      skus_count: new_item[:skus_count] - skus_count,
      # 收藏
      favs_count: new_item[:favs_count] - favs_count,
     total_sales: 0,
     month_sales: 0,
       qty_sales: 0,
    }
    # 判断下架、售罄时，仅通过json解析，是没有价格数据的。
    if new_item.has_key?(:price) 
      new_increment[:price] = (new_item[:price] - price).round(2) 
    end
    # 优惠活动
    if new_item[:prom_type] && new_item[:prom_price] > 0 
           new_increment[:prom_price] = (new_item[:prom_price] - prom_price).round(2)
        new_increment[:prom_discount] = new_item[:prom_discount] - prom_discount
    end
    # 无差异，讲不形成记录
    if (new_increment[:total_num] + new_increment[:month_num] + new_increment[:quantity]) == 0 
      nil
    else
      # 计算销售额
      new_increment[:total_sales] = new_increment[:total_num]    * prom_price if new_increment[:total_num] > 0
      new_increment[:month_sales] = new_increment[:month_num]    * prom_price if new_increment[:month_num] > 0
      new_increment[:qty_sales]   = new_increment[:quantity].abs * prom_price if new_increment[:quantity]  < 0

      new_increment
    end
  end

  def show_status
    case status
    when 'onsale'
      '在售'
    when 'soldout'
      '售罄'
    when 'inventory'
      '下架'
    end
  end

  def item_url
    'http://detail.tmall.com/item.htm?id=' << num_iid.to_s
  end

  class << self

    def sync(threading, seller_nick, page_dom)
      # 起始化
      unless defined?(@threading)
        @threading = threading
      end
      if @threading.has_key?(seller_nick)
        # 执行分页
        each_pages(seller_nick, page_dom) if page_dom
        # 批量处理，促销
        # each_campaigns(seller_nick)
        return @threading[seller_nick]
      else
        nil
      end
    end

    def recycling(threading, seller_nick, item_ids)  
      # 起始化
      unless defined?(@threading)
        @threading = threading
      end
      if @threading.has_key?(seller_nick)
        item_ids.each do |item_id|
          item = { num_iid: item_id, status: 'inventory', timestamp: @threading[:timestamp], category_ids: [], campaign_ids: [] }
          # 获取销售信息
          set_item_sales(seller_nick, item)
        end
        logger.warn "同步批次号：#{@threading[:timestamp]}。"
        return @threading[seller_nick]
      else
        nil
      end
    end

    def each_items(items)
      logger.info "批量处理，宝贝信息。"
      item_timelines = {}
      items.each do |item_id, item|
        current_item = Item.where(seller_nick: item[:seller_nick], _id: item_id).first
        item[:campaign_ids] = item[:campaign_ids].uniq.compact # 去重、去空
        item[:category_ids] = item[:category_ids].uniq.compact # 去重、去空
        if current_item
          # 设定历史版本，计算增量信息
          timeline = current_item.item_timeline(item)
          if timeline # 无差异，讲不形成记录
            unless current_item.campaign_ids == item[:campaign_ids]
              item[:campaign_ids] = (current_item.campaign_ids && item[:campaign_ids])
            end
            unless current_item.category_ids == item[:category_ids]
              item[:category_ids] = (current_item.category_ids && item[:category_ids])
            end
            item[:timelines] = current_item.timelines << ItemTimeline.new(timeline)
            current_item.update_attributes(item)
            # 统计当量
            item.delete(:timelines)
            item[:timeline] = timeline
          else
            logger.warn "宝贝无变化，跳过。"
          end
        else
          Item.create(item)
        end
        item_timelines[item_id] = item
      end
      return item_timelines
    end

    private

    def each_pages(seller_id, page_dom=nil, page=2)
      # 分页执行
      if @threading[seller_id][:pages] > 1
        pages = @threading[seller_id][:pages]
        logger.warn "共 #{pages}页，开始执行分页操作。"
        page.upto(pages).each do |page|
          page_dom  = get_page_dom(seller_id, page)
          items_dom = get_items_dom(page_dom) if page_dom
          set_items(seller_id, items_dom) if items_dom
          logger.warn "第 #{page}/#{pages} 页。"
          @threading[seller_id][:page] = page # 设定当前页，以便断点续传
        end
        @threading[seller_id][:pages] = 1 # 用后清零
      elsif page_dom
        total = get_total(page_dom)
        if total < 1
          logger.error "本页没有货品。"
        else
          items_dom = get_items_dom(page_dom)
          if items_dom
            set_items(seller_id, items_dom)
            items_count = items_dom.count
            if total > items_count
              @threading[seller_id][:pages] = @threading[seller_id][:crawler].pages_count(total, items_count)
              pages = @threading[seller_id][:pages]
              logger.warn "货品共有 #{total}件，每页 #{items_count}件，分为 #{pages}页。"
              each_pages(seller_id) if pages > 1 # 内循环，执行分页
            end
          else
            logger.error "咦~，共有#{total}件货品呀？"
          end
        end
      end
    end

    def get_page_dom(seller_id, page=1)
      crawler = @threading[seller_id][:crawler]
      crawler.params = { 'pageNum' => page }
      crawler.item_search_url
      return crawler.get_dom
    end

    def set_items(seller_id, items_dom)
      items_dom.each do |item_dom|
        item = parse_item(seller_id, item_dom, @threading[:timestamp])
        if item && !@threading[seller_id][:items].has_key?(item[:num_iid])
          set_item_sales(seller_id, item)
        end
      end
    end

    def set_item_sales(seller_id, item)
      item_id = item[:num_iid]
      crawler = @threading[seller_id][:crawler]
      json    = crawler.tmall_item_json(@threading[seller_id][:id], item_id) # 地址被改变 
      if json # 宝贝销售数据
        sales      = parse_sales(seller_id, item_id, json) # 解析
        item.merge!(sales) # 合并
        # 宝贝收藏数
        favs_count = crawler.get_favs_count(item_id)
        item[:favs_count] = favs_count if favs_count
        # 注入集合
        @threading[seller_id][:items][item_id] = item
      else
        logger.error "宝贝 #{item_id}，获取销售数据时出错。"
      end
    end

    def set_campaign(seller_id, item_id, campaign) # 大促
      start_at    = to_date(campaign['startTime'])
      end_at      = to_date(campaign['endTime'])
      campaign_id = "#{seller_id}-#{start_at.to_i}-#{end_at.to_i}"
      # 收集促销活动
      campaigns = @threading[seller_id][:campaigns]
      if campaigns.has_key?(campaign_id)
        campaigns[campaign_id][:item_ids] << item_id
      else
        campaigns[campaign_id] = {
           seller_nick: seller_id,
              start_at: start_at, 
                end_at: end_at, 
                  name: campaign['campaignName'], 
              discount: (campaign['shopUnderFiftyPOff'] ? 50 : 100),
                  plan: campaign['promotionPlan'],
              item_ids: [item_id],
             timestamp: @threading[:timestamp]
        }
      end
      return campaign_id
    end

    include BaseParse
    include ItemParse
  end
end