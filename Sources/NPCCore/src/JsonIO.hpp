#pragma once
// Strict, path-reporting JSON decoding helpers and a compact writer (private to NPCCore).
#include "Codec.hpp"
#include "DialogueJson.hpp"

#include <charconv>
#include <cmath>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace npc::dialogue::io {

[[noreturn]] inline void fail(const std::string& path,const std::string& message){
    throw codec::DecodeError(path+": "+message);
}

// API payloads and project files: 16 MiB, depth 32.
inline json::Value parseDocument(std::string_view text,const std::string& path){
    auto v=json::parse(text,16u<<20,32);
    if(!v) fail(path,"is not valid JSON");
    return std::move(*v);
}

class Reader {
public:
    Reader(const json::Value& v,std::string path):v_(v),path_(std::move(path)){
        if(v.kind!=json::Kind::Object) fail(path_,"expected an object");
    }
    std::string pathOf(std::string_view key) const{return path_+"."+std::string(key);}
    const json::Value* get(std::string_view key){
        seen_.emplace_back(key);
        const json::Value* x=v_.find(key);
        return x&&x->kind!=json::Kind::Null?x:nullptr;
    }
    std::string str(std::string_view key,std::string_view fallback={}){
        const json::Value* x=get(key);
        if(!x) return std::string(fallback);
        if(x->kind!=json::Kind::String) fail(pathOf(key),"expected a string");
        return x->string;
    }
    bool boolean(std::string_view key,bool fallback){
        const json::Value* x=get(key);
        if(!x) return fallback;
        if(x->kind!=json::Kind::Bool) fail(pathOf(key),"expected true or false");
        return x->boolean;
    }
    double number(std::string_view key,double fallback){
        const json::Value* x=get(key);
        if(!x) return fallback;
        if(x->kind!=json::Kind::Number||!std::isfinite(x->number)) fail(pathOf(key),"expected a number");
        return x->number;
    }
    std::uint32_t u32(std::string_view key,std::uint32_t fallback){
        const double d=number(key,fallback);
        if(d<0||d>4294967295.0||d!=std::floor(d)) fail(pathOf(key),"expected a non-negative integer");
        return static_cast<std::uint32_t>(d);
    }
    std::uint64_t u64(std::string_view key,std::uint64_t fallback){
        const double d=number(key,static_cast<double>(fallback));
        if(d<0||d>9007199254740992.0||d!=std::floor(d)) fail(pathOf(key),"expected a non-negative integer up to 2^53");
        return static_cast<std::uint64_t>(d);
    }
    std::vector<std::string> strings(std::string_view key){
        std::vector<std::string> out;
        const json::Value* x=get(key);
        if(!x) return out;
        if(x->kind!=json::Kind::Array) fail(pathOf(key),"expected an array of strings");
        for(std::size_t i=0;i<x->array.size();++i){
            if(x->array[i].kind!=json::Kind::String) fail(pathOf(key)+"["+std::to_string(i)+"]","expected a string");
            out.push_back(x->array[i].string);
        }
        return out;
    }
    // Rejects keys nobody asked for (typos in authored files surface immediately).
    void finish() const{
        for(const auto& [k,_]:v_.object){
            bool known=false;
            for(const auto& s:seen_) if(s==k){known=true;break;}
            if(!known) fail(pathOf(k),"unknown key");
        }
    }
private:
    const json::Value& v_;
    std::string path_;
    std::vector<std::string> seen_;
};

template<class T,class F> std::vector<T> listOf(Reader& r,std::string_view key,F&& item){
    std::vector<T> out;
    const json::Value* v=r.get(key);
    if(!v) return out;
    const std::string path=r.pathOf(key);
    if(v->kind!=json::Kind::Array) fail(path,"expected an array");
    for(std::size_t i=0;i<v->array.size();++i) out.push_back(item(v->array[i],path+"["+std::to_string(i)+"]"));
    return out;
}

// Re-indents compact JSON (two spaces) for authored, diff-friendly files.
inline std::string pretty(std::string_view in){
    std::string o;
    int depth=0;
    bool str=false,esc=false;
    auto nl=[&]{o+='\n';o.append(static_cast<std::size_t>(depth)*2,' ');};
    for(std::size_t i=0;i<in.size();++i){
        char c=in[i];
        if(str){
            o+=c;
            if(esc) esc=false;
            else if(c=='\\') esc=true;
            else if(c=='"') str=false;
            continue;
        }
        switch(c){
        case '"':str=true;o+=c;break;
        case '{':case '[':
            o+=c;
            if(i+1<in.size()&&(in[i+1]=='}'||in[i+1]==']')){o+=in[++i];break;}
            ++depth;nl();break;
        case '}':case ']':--depth;nl();o+=c;break;
        case ',':o+=c;nl();break;
        case ':':o+=": ";break;
        default:o+=c;
        }
    }
    o+='\n';
    return o;
}

class Writer {
public:
    Writer& beginObject(){sep();out_+='{';first_.push_back(true);return *this;}
    Writer& endObject(){out_+='}';first_.pop_back();afterKey_=false;return *this;}
    Writer& beginArray(){sep();out_+='[';first_.push_back(true);return *this;}
    Writer& endArray(){out_+=']';first_.pop_back();afterKey_=false;return *this;}
    Writer& key(std::string_view k){sep();out_+=json::quote(k);out_+=':';afterKey_=true;return *this;}
    Writer& string(std::string_view s){sep();out_+=json::quote(s);return *this;}
    Writer& boolean(bool b){sep();out_+=b?"true":"false";return *this;}
    Writer& number(double d){
        sep();
        if(!std::isfinite(d)){out_+="null";return *this;}
        char buf[32];
        auto r=std::to_chars(buf,buf+sizeof buf,d);
        out_.append(buf,r.ptr);
        return *this;
    }
    Writer& raw(std::string_view json){sep();out_+=json;return *this;}
    Writer& strings(const std::vector<std::string>& v){
        beginArray();
        for(const auto& s:v) string(s);
        return endArray();
    }
    std::string take(){return std::move(out_);}
private:
    void sep(){
        if(afterKey_){afterKey_=false;return;}
        if(first_.empty()) return;
        if(first_.back()) first_.back()=false;
        else out_+=',';
    }
    std::string out_;
    std::vector<bool> first_;
    bool afterKey_{false};
};

} // namespace npc::dialogue::io
