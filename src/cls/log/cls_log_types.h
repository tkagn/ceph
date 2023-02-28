// -*- mode:C++; tab-width:8; c-basic-offset:2; indent-tabs-mode:t -*-
// vim: ts=8 sw=2 smarttab
#ifndef CEPH_CLS_LOG_TYPES_H
#define CEPH_CLS_LOG_TYPES_H

#include <string>

#include "include/buffer.h"
#include "include/encoding.h"
#include "include/types.h"

#include "common/ceph_time.h"

class JSONObj;

namespace cls::log {
struct entry {
  std::string id;
  std::string section;
  std::string name;
  ceph::real_time timestamp;
  ceph::buffer::list data;

  entry() = default;

  entry(ceph::real_time timestamp, std::string section,
	std::string name, ceph::buffer::list&& data)
    : section(std::move(section)), name(std::move(name)),
      timestamp(timestamp), data(std::move(data)) {}

  void encode(ceph::buffer::list& bl) const {
    ENCODE_START(2, 1, bl);
    encode(section, bl);
    encode(name, bl);
    encode(timestamp, bl);
    encode(data, bl);
    encode(id, bl);
    ENCODE_FINISH(bl);
  }

  void decode(ceph::buffer::list::const_iterator& bl) {
    DECODE_START(2, bl);
    decode(section, bl);
    decode(name, bl);
    decode(timestamp, bl);
    decode(data, bl);
    if (struct_v >= 2)
      decode(id, bl);
    DECODE_FINISH(bl);
  }
};
WRITE_CLASS_ENCODER(entry)

struct header {
  std::string max_marker;
  ceph::real_time max_time;

  void encode(ceph::buffer::list& bl) const {
    ENCODE_START(1, 1, bl);
    encode(max_marker, bl);
    encode(max_time, bl);
    ENCODE_FINISH(bl);
  }

  void decode(ceph::buffer::list::const_iterator& bl) {
    DECODE_START(1, bl);
    decode(max_marker, bl);
    decode(max_time, bl);
    DECODE_FINISH(bl);
  }

  friend auto operator <=>(const header&, const header&) = default;
};
WRITE_CLASS_ENCODER(header)
} // namespace cls::log

#endif
