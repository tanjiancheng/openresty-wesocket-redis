local redis = require "resty.redis" 
local cjson = require "cjson"
local server = require "resty.websocket.server"

--redis 服务器配置
local _redis_config = {
	redis_host = '127.0.0.1', 
	redis_port = 6379
}

-- ip限制
local _white_list = {
	'10.0.2.2',
	'127.0.0.1',
	'localhost'
}

-- 检测客户端限制
local _check_ip = function()
	local ip = ngx.var.remote_addr
	for k,v in ipairs(_white_list) do
		if v == ip then
			return true
		end
	end
	ngx.log(ngx.INFO, "ip limit:" .. ip, err)
	return ngx.exit(403) 
end


-- 获取redis客户端
local _get_redis_client = function()
	local red = redis:new() 
	red:set_timeout(5000)
	local ok, err = red:connect(_redis_config.redis_host, _redis_config.redis_port)
	if not ok then
    	ngx.log(ngx.ERR, "connect to redis server failed: ", err)
    	return ngx.exit(444)
	end
	return red
end

-- 检测参数
local _check_args = function()
	local args = ngx.req.get_uri_args()
	local channel = args.channel
	if string.len(channel) == 0 then
		ngx.log(ngx.ERR, "invalid channel:" .. channel)
    	return ngx.exit(444)
    end

    ngx.log(ngx.INFO, "current channel:" .. channel)
	return {
		channel = channel
	} 	
end

-- 获取频道名称
local channel = _check_args().channel


-- 创建websocket服务端
local wb, err = server:new{ 
	timeout = 5000, 
	max_payload_len = 65535 
}
if not wb then 
	ngx.log(ngx.ERR, "failed to new websocket: ", err)
	wb:send_close()
	return
end

-- 订阅消息
local sub = function()
	-- 检测ip合法性
	_check_ip()

	-- 获取redis连接
	local client = _get_redis_client()

	-- 订阅频道
	local res, err = client:subscribe(channel)
	if not res then 
		ngx.say("failed to subscribe: ", err) 
		wb:send_close()
		return
	end

	-- 从redis频道读取内容
	while true do 
		local res, err = client:read_reply() 
		if res then 
			local content = res[3]
			ngx.log(ngx.ERR, "recv message:", content)
			local bytes, err = wb:send_text(content)
			if not bytes then
		        ngx.log(ngx.ERR, "failed to send a text frame: ", err)
        		return ngx.exit(444)
		    end
		end	
	end

end

-- 新开线程监听频道，实现wesocket全双工模式
local sub = ngx.thread.spawn(sub)


-- 发布消息
local pub = function()
	-- 检测ip合法性
	_check_ip()

	while true do 
		-- 获取数据
		local data, typ, err = wb:recv_frame() 

		-- 如果连接损坏 退出
		if wb.fatal then
			ngx.log(ngx.ERR, "failed to receive frame: ", err)
        	return ngx.exit(444)
    	end


        if not data then
        	local bytes, err = wb:send_ping()
        	if not bytes then
          		ngx.log(ngx.ERR, "failed to send ping: ", err)
          		return ngx.exit(444)
        	end
    	elseif typ == "close" then
        	break
    	elseif typ == "ping" then
        	local bytes, err = wb:send_pong()
        	if not bytes then
            	ngx.log(ngx.ERR, "failed to send pong: ", err)
            	return ngx.exit(444)
        	end
    	elseif typ == "pong" then
        	ngx.log(ngx.ERR, "client ponged")
    	elseif typ == "text" then
       		-- 获取redis连接
			local client = _get_redis_client()
			ngx.log(ngx.INFO, "publish channel:" .. channel .. ",message:" .. data)

			local res, err = client:publish(channel, data)
        	if not res then
	            ngx.log(ngx.ERR, "failed to publish redis: ", err)
	        end
	        client:close()	
        end
	end
	wb:send_close()
end


pub()
ngx.thread.wait(sub)