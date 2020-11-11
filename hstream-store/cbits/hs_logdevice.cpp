#include <cstdlib>
#include <folly/Optional.h>
#include <folly/Singleton.h>
#include <logdevice/include/BufferedWriter.h>
#include <logdevice/include/Client.h>
#include <logdevice/include/Err.h>
#include <logdevice/include/Reader.h>
#include <logdevice/include/Record.h>
#include <logdevice/include/RecordOffset.h>
#include <logdevice/include/debug.h>
#include <logdevice/include/types.h>

#include "hs_logdevice.h"

using facebook::logdevice::append_callback_t;
using facebook::logdevice::AppendAttributes;
using facebook::logdevice::AsyncReader;
using facebook::logdevice::BufferedWriter;
using facebook::logdevice::Client;
using facebook::logdevice::ClientFactory;
using facebook::logdevice::DataRecord;
using facebook::logdevice::GapRecord;
using facebook::logdevice::GapType;
using facebook::logdevice::KeyType;
using facebook::logdevice::logid_t;
using facebook::logdevice::lsn_t;
using facebook::logdevice::Payload;
using facebook::logdevice::PayloadGroup;
using facebook::logdevice::Reader;

extern "C" {

struct logdevice_client_t {
  std::shared_ptr<Client> rep;
};
struct logdevice_buffered_writer_t {
  std::unique_ptr<BufferedWriter> rep;
};
struct logdevice_reader_t {
  std::unique_ptr<Reader> rep;
};
struct logdevice_async_reader_t {
  std::unique_ptr<AsyncReader> rep;
};

// ----------------------------------------------------------------------------

void set_dbg_level_error(void) {
  facebook::logdevice::dbg::currentLevel =
      facebook::logdevice::dbg::Level::ERROR;
}
void init_logdevice(void) {
  folly::SingletonVault::singleton()->registrationComplete();
}

// ----------------------------------------------------------------------------
// Init & Destroy

logdevice_client_t *new_logdevice_client(char *config_path) {
  std::shared_ptr<Client> client = ClientFactory().create(config_path);
  if (!client) {
    fprintf(stderr,
            "logdevice::ClientFactory().create() failed. Check the config "
            "path.\n");
    exit(1);
  }
  logdevice_client_t *result = new logdevice_client_t;
  result->rep = client;

  return result;
}
void free_logdevice_client(logdevice_client_t *client) { delete client; }

logdevice_reader_t *new_logdevice_reader(logdevice_client_t *client,
                                         size_t max_logs,
                                         ssize_t *buffer_size) {
  std::unique_ptr<Reader> reader;
  if (buffer_size)
    reader = client->rep->createReader(max_logs, *buffer_size);
  else
    reader = client->rep->createReader(max_logs);
  logdevice_reader_t *result = new logdevice_reader_t;
  result->rep = std::move(reader);
  return result;
}
void free_logdevice_reader(logdevice_reader_t *reader) { delete reader; }

// ----------------------------------------------------------------------------
// Writer

lsn_t append_sync(logdevice_client_t *client, uint64_t logid,
                  const char *payload, int64_t *ts) {
  lsn_t result;
  if (ts) {
    std::chrono::milliseconds timestamp;
    result = client->rep->appendSync(logid_t(logid), payload,
                                     AppendAttributes(), &timestamp);
    *ts = timestamp.count();
  } else {
    result = client->rep->appendSync(logid_t(logid), payload,
                                     AppendAttributes(), nullptr);
  }
  return result;
}

// ----------------------------------------------------------------------------
// Reader

int start_reading(logdevice_reader_t *reader, uint64_t logid, lsn_t start_lsn,
                   lsn_t until_lsn, bool wait_only_when_no_data) {
  int rv __attribute__((__unused__)) =
      reader->startReading(logid, start_lsn, until_lsn);
  if (rv != 0) {
    fprintf(stderr, "StartReading Error [%s]: %s\n",
            facebook::logdevice::error_name(facebook::logdevice::err),
            facebook::logdevice::error_description(facebook::logdevice::err));
    return rv;
  }
  if (wait_only_when_no_data) {
    reader->waitOnlyWhenNoData();
  }
  return 0;
}

// void read(logdevice_reader_t *reader, logdevice_read_callback_t *cb,
//          size_t nrecords) {
//  int exit_code = 0;
//  bool done = false;
//  std::vector<std::unique_ptr<DataRecord>> data;
//  do {
//    data.clear();
//    GapRecord gap;
//    ssize_t nread = reader->read(nrecords, &data, &gap);
//    if (nread >= 0) {
//      // Got some data, print to stdout
//      for (auto &record_ptr : data) {
//        const facebook::logdevice::Payload &payload = record_ptr->payload;
//        ::fwrite(payload.data(), 1, payload.size(), stdout);
//        ::putchar('\n');
//        if (record_ptr->attrs.lsn == until_lsn) {
//          done = true;
//        }
//      }
//    } else {
//      // A gap in the numbering sequence.  Warn about data loss but ignore
//      // other types of gaps.
//      if (gap.type == facebook::logdevice::GapType::DATALOSS) {
//        fprintf(stderr, "warning: DATALOSS gaps for LSN range [%ld, %ld]\n",
//                gap.lo, gap.hi);
//        exit_code = 1;
//      }
//      if (gap.hi == until_lsn) {
//        done = true;
//      }
//    }
//  } while (!done);
//  return exit_code;
//}

// ----------------------------------------------------------------------------
} // end extern "C"
