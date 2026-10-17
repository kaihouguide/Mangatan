#include "hoshidicts_c_api.h"

#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "hoshidicts.h"

namespace {
struct LookupSession {
  std::unique_ptr<DictionaryQuery> query;
  std::unique_ptr<Deinflector> deinflector;
  std::unique_ptr<Lookup> lookup;

  LookupSession()
      : query(std::make_unique<DictionaryQuery>()),
        deinflector(std::make_unique<Deinflector>()),
        lookup(std::make_unique<Lookup>(*query, *deinflector)) {}

  void rebuild(const char* const* term_paths, size_t term_count, const char* const* freq_paths, size_t freq_count,
               const char* const* pitch_paths, size_t pitch_count) {
    auto next_query = std::make_unique<DictionaryQuery>();
    for_each_path(term_paths, term_count, [&](const char* path) { next_query->add_term_dict(path); });
    for_each_path(freq_paths, freq_count, [&](const char* path) { next_query->add_freq_dict(path); });
    for_each_path(pitch_paths, pitch_count, [&](const char* path) { next_query->add_pitch_dict(path); });

    auto next_lookup = std::make_unique<Lookup>(*next_query, *deinflector);
    lookup = std::move(next_lookup);
    query = std::move(next_query);
  }

  template <typename Fn>
  static void for_each_path(const char* const* paths, size_t count, Fn fn) {
    if (paths == nullptr) {
      return;
    }
    for (size_t i = 0; i < count; ++i) {
      if (paths[i] != nullptr && paths[i][0] != '\0') {
        fn(paths[i]);
      }
    }
  }
};

LookupSession* as_session(void* session) {
  if (session == nullptr) {
    throw std::invalid_argument("Hoshidicts session is null");
  }
  return reinterpret_cast<LookupSession*>(session);
}

void append_json_string(std::ostringstream& out, std::string_view value) {
  out << '"';
  for (unsigned char c : value) {
    switch (c) {
      case '"':
        out << "\\\"";
        break;
      case '\\':
        out << "\\\\";
        break;
      case '\b':
        out << "\\b";
        break;
      case '\f':
        out << "\\f";
        break;
      case '\n':
        out << "\\n";
        break;
      case '\r':
        out << "\\r";
        break;
      case '\t':
        out << "\\t";
        break;
      default:
        if (c < 0x20) {
          out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c) << std::dec
              << std::setfill(' ');
        } else {
          out << static_cast<char>(c);
        }
    }
  }
  out << '"';
}

template <typename T, typename Fn>
void append_json_array(std::ostringstream& out, const std::vector<T>& values, Fn append_item) {
  out << '[';
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) {
      out << ',';
    }
    append_item(out, values[i]);
  }
  out << ']';
}

void append_string_array(std::ostringstream& out, const std::vector<std::string>& values) {
  append_json_array(out, values, [](std::ostringstream& out, const std::string& value) { append_json_string(out, value); });
}

void append_int_array(std::ostringstream& out, const std::vector<int>& values) {
  append_json_array(out, values, [](std::ostringstream& out, int value) { out << value; });
}

void append_transform_group(std::ostringstream& out, const TransformGroup& group) {
  out << "{\"name\":";
  append_json_string(out, group.name);
  out << ",\"description\":";
  append_json_string(out, group.description);
  out << '}';
}

void append_glossary_entry(std::ostringstream& out, const GlossaryEntry& entry) {
  out << "{\"dictName\":";
  append_json_string(out, entry.dict_name);
  out << ",\"glossary\":";
  append_json_string(out, entry.glossary);
  out << ",\"definitionTags\":";
  append_json_string(out, entry.definition_tags);
  out << ",\"termTags\":";
  append_json_string(out, entry.term_tags);
  out << '}';
}

void append_frequency(std::ostringstream& out, const Frequency& frequency) {
  out << "{\"value\":" << frequency.value << ",\"displayValue\":";
  append_json_string(out, frequency.display_value);
  out << '}';
}

void append_frequency_entry(std::ostringstream& out, const FrequencyEntry& entry) {
  out << "{\"dictName\":";
  append_json_string(out, entry.dict_name);
  out << ",\"frequencies\":";
  append_json_array(out, entry.frequencies, append_frequency);
  out << '}';
}

void append_pitch_entry(std::ostringstream& out, const PitchEntry& entry) {
  out << "{\"dictName\":";
  append_json_string(out, entry.dict_name);
  out << ",\"pitchPositions\":";
  std::vector<int> pitch_positions;
  pitch_positions.reserve(entry.pitches.size());
  for (const auto& pitch : entry.pitches) {
    pitch_positions.push_back(pitch.position);
  }
  append_int_array(out, pitch_positions);
  out << ",\"transcriptions\":";
  append_string_array(out, entry.transcriptions);
  out << '}';
}

void append_term_result(std::ostringstream& out, const TermResult& term) {
  out << "{\"expression\":";
  append_json_string(out, term.expression);
  out << ",\"reading\":";
  append_json_string(out, term.reading);
  out << ",\"rules\":";
  append_json_string(out, term.rules);
  out << ",\"score\":" << term.score;
  out << ",\"glossaries\":";
  append_json_array(out, term.glossaries, append_glossary_entry);
  out << ",\"frequencies\":";
  append_json_array(out, term.frequencies, append_frequency_entry);
  out << ",\"pitches\":";
  append_json_array(out, term.pitches, append_pitch_entry);
  out << '}';
}

void append_lookup_result(std::ostringstream& out, const LookupResult& result) {
  out << "{\"matched\":";
  append_json_string(out, result.matched);
  out << ",\"deinflected\":";
  append_json_string(out, result.deinflected);
  out << ",\"trace\":";
  append_json_array(out, result.trace, append_transform_group);
  out << ",\"preprocessorSteps\":" << result.preprocessor_steps;
  out << ",\"term\":";
  append_term_result(out, result.term);
  out << '}';
}

void append_dictionary_style(std::ostringstream& out, const DictionaryStyle& style) {
  out << "{\"dictName\":";
  append_json_string(out, style.dict_name);
  out << ",\"styles\":";
  append_json_string(out, style.styles);
  out << '}';
}

char* duplicate_string(const std::string& value) {
  auto* copy = static_cast<char*>(std::malloc(value.size() + 1));
  if (copy == nullptr) {
    return nullptr;
  }
  std::memcpy(copy, value.c_str(), value.size() + 1);
  return copy;
}

char* error_json(std::string_view message) {
  std::ostringstream out;
  out << "{\"success\":false,\"error\":";
  append_json_string(out, message);
  out << '}';
  return duplicate_string(out.str());
}

char* error_json(const std::exception& error) { return error_json(error.what()); }

// An exception leaving an extern "C" function terminates the process, so a
// non-std throw from the dictionary library is reported like any other error.
constexpr std::string_view kUnknownError = "Unknown hoshidicts error";
char* import_error_json(std::string_view message) {
  std::ostringstream out;
  out << "{\"success\":false,\"title\":\"\",\"termCount\":0,\"metaCount\":0,\"freqCount\":0,\"pitchCount\":0,"
         "\"mediaCount\":0,\"errors\":[";
  append_json_string(out, message);
  out << "]}";
  return duplicate_string(out.str());
}
}  // namespace

extern "C" char* hoshidicts_import_dictionary_json(const char* zip_path, const char* output_dir, bool low_ram) {
  try {
    if (zip_path == nullptr || output_dir == nullptr) {
      throw std::invalid_argument("zip_path and output_dir are required");
    }

    const auto result = dictionary_importer::import(zip_path, output_dir, low_ram);
    const auto meta_count = [&result](std::string_view mode) {
      const auto it = result.summary.counts.termMeta.find(std::string(mode));
      return it == result.summary.counts.termMeta.end() ? size_t{0} : it->second;
    };
    std::ostringstream out;
    out << "{\"success\":" << (result.success ? "true" : "false");
    out << ",\"title\":";
    append_json_string(out, result.title);
    out << ",\"termCount\":" << result.summary.counts.terms.total;
    out << ",\"metaCount\":" << meta_count("total");
    out << ",\"freqCount\":" << meta_count("freq");
    out << ",\"pitchCount\":" << (meta_count("pitch") + meta_count("ipa"));
    out << ",\"mediaCount\":" << result.summary.counts.media.total;
    out << ",\"errors\":";
    if (result.error.empty()) {
      append_string_array(out, {});
    } else {
      append_string_array(out, {result.error});
    }
    out << '}';
    return duplicate_string(out.str());
  } catch (const std::exception& error) {
    return import_error_json(error.what());
  } catch (...) {
    return import_error_json(kUnknownError);
  }
}

extern "C" void* hoshidicts_create_lookup_session(void) {
  try {
    return new LookupSession();
  } catch (...) {
    return nullptr;
  }
}

extern "C" void hoshidicts_destroy_lookup_session(void* session) {
  delete reinterpret_cast<LookupSession*>(session);
}

extern "C" char* hoshidicts_rebuild_query_json(void* session, const char* const* term_paths, size_t term_count,
                                                const char* const* freq_paths, size_t freq_count,
                                                const char* const* pitch_paths, size_t pitch_count) {
  try {
    as_session(session)->rebuild(term_paths, term_count, freq_paths, freq_count, pitch_paths, pitch_count);
    return duplicate_string("{\"success\":true}");
  } catch (const std::exception& error) {
    return error_json(error);
  } catch (...) {
    return error_json(kUnknownError);
  }
}

extern "C" char* hoshidicts_lookup_json(void* session, const char* text, int max_results, size_t scan_length) {
  try {
    if (text == nullptr) {
      throw std::invalid_argument("text is required");
    }
    const auto results = as_session(session)->lookup->lookup(text, max_results, scan_length);
    std::ostringstream out;
    out << "{\"results\":";
    append_json_array(out, results, append_lookup_result);
    out << '}';
    return duplicate_string(out.str());
  } catch (const std::exception& error) {
    return error_json(error);
  } catch (...) {
    return error_json(kUnknownError);
  }
}

extern "C" char* hoshidicts_styles_json(void* session) {
  try {
    const auto styles = as_session(session)->query->get_styles();
    std::ostringstream out;
    out << "{\"styles\":";
    append_json_array(out, styles, append_dictionary_style);
    out << '}';
    return duplicate_string(out.str());
  } catch (const std::exception& error) {
    return error_json(error);
  } catch (...) {
    return error_json(kUnknownError);
  }
}

extern "C" HoshiBytes hoshidicts_get_media_file(void* session, const char* dict_name, const char* media_path) {
  try {
    if (dict_name == nullptr || media_path == nullptr) {
      return {nullptr, 0};
    }
    const auto data = as_session(session)->query->get_media_file(dict_name, media_path);
    if (data.empty()) {
      return {nullptr, 0};
    }
    auto* copy = static_cast<uint8_t*>(std::malloc(data.size()));
    if (copy == nullptr) {
      return {nullptr, 0};
    }
    std::memcpy(copy, data.data(), data.size());
    return {copy, data.size()};
  } catch (...) {
    return {nullptr, 0};
  }
}

extern "C" void hoshidicts_free_string(char* value) {
  std::free(value);
}

extern "C" void hoshidicts_free_bytes(HoshiBytes value) {
  std::free(value.data);
}
