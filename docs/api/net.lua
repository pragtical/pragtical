---@meta

---
---Core functionality that allows non-blocking network communication with
---encryption support (SSL) on TCP connections.
---@class net
net = {}

---
---A network address.
---@class net.address
net.address = {}

---
---A network server that can accept connections.
---@class net.server
net.server = {}

---
---A TCP network connection.
---@class net.tcp
net.tcp = {}

---
---A UDP network connection.
---@class net.udp
net.udp = {}

---
---A UDP datagram.
---@class net.datagram
net.datagram = {}

---@alias net.status "success" | "waiting" | "failure"

---
---Set the path of CA bundle to use for validation on ssl connections.
---
---Note: on linux, freebsd and other unix based operating systems the
---default system bundle will be use if found. On windows and macOS
---you will need to set a CA bundle manually, if not set, transmission of data
---thru a ssl connection will still work but, validation of certificates
---authenticity will not be performed.
---
---@param path string
function net.set_cacert_path(path) end

---
---Get the currently set CA bundle use for validation on ssl connections.
---
---Note: on linux, freebsd and other unix based operating systems the
---default system bundle will be returned if found. On windows and macOS
---this will always return nil so you will need to set a CA bundle manually,
---transmission of data thru a ssl connection will still work but, validation
---of certificates authenticity will not be performed.
---
---@return string? cacert_bundle_path
function net.get_cacert_path() end

---
---Solve a domain or ip to a valid network address.
---
---@param address string Can be a domain or ip.
---@return net.address? address
---@return string? errmsg
function net.resolve_address(address) end

---
---Get a list of available local addresses.
---
---@return net.address[]? addresses
---@return string? errmsg
function net.get_local_addresses() end

---
---Opens a new TCP connection.
---
---@param address net.address
---@param port integer
---@param ssl? boolean
---@return net.tcp? connection
---@return string? errmsg
function net.open_tcp(address, port, ssl) end

---
---Opens a new UDP connection.
---
---@param address net.address
---@param port integer
---@return net.udp? connection
---@return string? errmsg
function net.open_udp(address, port) end

---
---Creates a new network server that listen for connections on the specified
---port. If the address is not specified it will listen on all interfaces.
---
---@param address net.address
---@param port integer
---@return net.server? connection
---@return string? errmsg
---@overload fun(port:integer):connection:net.udp?,errmsg:string?
function net.create_server(address, port) end

---
---Wait the specified amount of milliseconds for the address to resolve.
---
---If the specified timeout is -1 it will wait until it resolves, if
---0 will not wait and just return current status, any value longer than 0
---will be the maximum wait time in milliseconds.
---
---@param timeout? integer Timeout in milliseconds. Default: 0
---@return net.status status
---@return string? errmsg Error message on case of 'failure'.
function net.address:wait_until_resolved(timeout) end

---
---Get the current resolve status of the address without waiting.
---
---@return net.status status
---@return string? errmsg Error message on case of 'failure'.
function net.address:get_status() end

---
---Get ip address of resolved address.
---
---@return string? ip
function net.address:get_ip() end

---
---Get initial hostname or ip address if hostname not available.
---
---@return string hostname
function net.address:get_hostname() end

---
---String representation of the address (same as get_hostname).
---
---@return string hostname
function net.address:__tostring() end

---
---Check for new client connections and if found return it.
---
---@return net.tcp? client
---@return string? errmsg
function net.server:accept() end

---
---Get the listening port of the server.
---
---@return integer port
function net.server:get_port() end

---
---Get the listening port of the server.
---
---If the specified timeout is -1 it will wait until connected, if
---0 will not wait and just return current status, any value longer than 0
---will be the maximum wait time in milliseconds.
---
---@param timeout? integer Timeout in milliseconds. Default: 0
---@return net.status status
---@return string? errmsg Error message on case of 'failure'.
function net.tcp:wait_until_connected(timeout) end

---
---Get the associated address for the connection.
---
---If the specified timeout is -1 it will wait until connected, if
---0 will not wait and just return current status, any value longer than 0
---will be the maximum wait time in milliseconds.
---
---@return net.address? address
---@return string? errmsg
function net.tcp:get_address() end

---
---Get the current connection status without waiting.
---
---@return net.status address
---@return string? errmsg Error message on case of 'failure'.
function net.tcp:get_status() end

---
---Get the current connection status without waiting.
---
---@param data string
---@return boolean written
---@return string? errmsg Error message if not written.
function net.tcp:write(data) end

---
---Get total amount of bytes that haven't been written yet.
---
---@param data string
---@return integer? bytes
---@return string? errmsg Error message on error.
function net.tcp:get_pending_writes(data) end

---
---Waits the specified amount of time until all sent data is written.
---
---If the specified timeout is -1 it will wait until all is written, if
---0 will not wait and just return pending bytes, any value longer than 0
---will be the maximum wait time in milliseconds.
---
---@param timeout? integer Timeout in milliseconds. Default: 0
---@return integer? pending_bytes
---@return string? errmsg Error message on error.
function net.tcp:wait_until_drained(timeout) end

---
---Read the specified amount of bytes from the connection.
---
---Note: This function will usually return empty string if no data is
---available yet and nil if conneciton is closed or an error occurred,
---if an error occurred it will also return an error message string.
---
---@param amount integer Total amount of bytes to read.
---@return string? data
---@return string? errmsg Error message on error.
function net.tcp:read(amount) end

---
---Close the TCP connection by destroying it.
function net.tcp:close() end

---
---Send data on a UDP connection.
---
---@param address net.address
---@param port integer
---@param data string
---@return boolean sent
---@return string? errmsg
function net.udp:send(address, port, data) end

---
---Receive data on a UDP connection.
---
---Note: This function will usually return nil if no data is available yet
---and nil also if an error occurred which will be accompanied of the error
---message string.
---
---@return net.datagram? datagram
---@return string? errmsg Error message on error.
function net.udp:receive() end

---
---Close the UDP connection by destroying it.
function net.udp:close() end

---
---Get the data associated to a UDP datagram.
---
---@return string data
function net.datagram:get_data() end

---
---Get the address associated to a UDP datagram.
---
---@return net.address address
function net.datagram:get_address() end

---
---Get the port associated to a UDP datagram.
---
---@return integer port
function net.datagram:get_port() end

return net
