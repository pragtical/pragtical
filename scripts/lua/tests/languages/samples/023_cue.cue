package demo

#Service: {
  name: string
  port: int & >=1024 & <=65535
  enabled: bool | *true
}

service: #Service & {
  name: "api"
  port: 8080
}
