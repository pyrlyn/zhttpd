//! WSGI is executed by modules/wsgi/server.py using Python's PEP 3333 handler.
//! The HTTP runtime communicates with that isolated process over FastCGI.
pub const gateway_script = "modules/wsgi/server.py";
pub const default_address = "127.0.0.1:9000";
pub const protocol = @import("fastcgi");
