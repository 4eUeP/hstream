#include <grpcpp/server.h>

#include "HStream/Server/HStreamApi.grpc.pb.h"

namespace hs = hstream::server;

template <typename Request> struct ClientInfo {
  std::string& client_id;
  Request& req;
};

template <typename Request>
class RewriteResouceNameInterceptor : public grpc::experimental::Interceptor {
public:
  explicit RewriteResouceNameInterceptor(
      std::string&& rpc_name,
      std::function<void(ClientInfo<Request>&)>& process_fn,
      grpc::experimental::ServerRpcInfo* info)
      : process_fn_(process_fn) {
    std::string method_ = "/hstream.server.HStreamApi/";
    method_.append(rpc_name);
    if (std::string(info->method()) == method_) {
      should_intercept_ = true;
      // TODO
      printf("-----------%p %p \n", info->server_context(),
             info->server_context()->auth_context());

      printf("--------- %s\n", info->server_context()->peer().c_str());

      auto auth_context = info->server_context()->auth_context();
      if (auth_context) {
        std::string n = auth_context->GetPeerIdentityPropertyName();
        std::cout << "----- PeerIdentityPropertyName " << n << std::endl;
        auto vals = info->server_context()->auth_context()->FindPropertyValues(
            "x509_common_name");
        std::cout << "----- CommonNames " << vals[0] << std::endl;
      } else {
        std::cout << "----- no auto_context" << std::endl;
      }
    }
  }

  void
  Intercept(grpc::experimental::InterceptorBatchMethods* methods) override {
    if (should_intercept_ &&
        methods->QueryInterceptionHookPoint(
            grpc::experimental::InterceptionHookPoints::POST_RECV_MESSAGE)) {
      auto msg_bs = static_cast<grpc::ByteBuffer*>(methods->GetRecvMessage());
      if (msg_bs) {
        // Deserialize
        Request msg;
        // Note: grpc::GenericDeserialize will clear the input buffer
        const auto deserialize_status =
            grpc::GenericDeserialize<grpc::ProtoBufferReader, Request>(msg_bs,
                                                                       &msg);
        if (!deserialize_status.ok()) {
          fprintf(stderr, "Unexpected error: HStreamRpcReqInterceptor "
                          "deserialize request failed.\n");
        }
        // Process request
        // TODO
        std::string client_id = "xx";
        ClientInfo<Request> info{client_id, msg};
        process_fn_(info);
        // Serialize
        bool own_buffer;
        grpc::GenericSerialize<grpc::ProtoBufferWriter, Request>(msg, msg_bs,
                                                                 &own_buffer);
      } else {
        fprintf(stderr, "Interceptor: GetSerializedSendMessage failed.\n");
      }
    }
    methods->Proceed();
  }

private:
  bool should_intercept_{false};
  std::function<void(ClientInfo<Request>&)>& process_fn_;
};

template <typename Request>
class RewriteResouceNameInterceptorFactory
    : public grpc::experimental::ServerInterceptorFactoryInterface {

public:
  explicit RewriteResouceNameInterceptorFactory(
      std::string rpc_name,
      std::function<void(ClientInfo<Request>&)> process_fn)
      : rpc_name_(std::move(rpc_name)), process_fn_(std::move(process_fn)) {}

  grpc::experimental::Interceptor*
  CreateServerInterceptor(grpc::experimental::ServerRpcInfo* info) override {
    return new RewriteResouceNameInterceptor<Request>(std::move(rpc_name_),
                                                      process_fn_, info);
  }

private:
  std::string rpc_name_;
  std::function<void(ClientInfo<Request>&)> process_fn_;
};

// ----------------------------------------------------------------------------
extern "C" {

grpc::experimental::ServerInterceptorFactoryInterface*
createStreamInterceptorFactory() {
  return new RewriteResouceNameInterceptorFactory<hs::Stream>(
      "CreateStream", [](ClientInfo<hs::Stream>& info) {
        std::cout << "------------" << info.client_id << std::endl;
      });
}

// ----------------------------------------------------------------------------
} // End extern "C"
