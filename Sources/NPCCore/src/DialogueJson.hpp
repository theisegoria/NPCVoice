#pragma once
// Minimal strict JSON reader/writer for model responses (private to NPCCore).
// Bounded: 64 KiB input and depth 16 by default. Rejects trailing garbage, raw control
// characters in strings and lone surrogates.
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace npc::dialogue::json {

enum class Kind : std::uint8_t {Null,Bool,Number,String,Array,Object};
struct Value {
    Kind kind{Kind::Null};
    bool boolean{false};
    double number{0};
    std::string string;
    std::vector<Value> array;
    std::vector<std::pair<std::string,Value>> object;
    const Value* find(std::string_view key) const{
        for(const auto& [k,v]:object) if(k==key) return &v;
        return nullptr;
    }
};

namespace detail {
struct Parser {
    std::string_view s;
    std::size_t i{0};
    int depth{0};
    int maxDepth{16};
    void ws(){while(i<s.size()&&(s[i]==' '||s[i]=='\t'||s[i]=='\n'||s[i]=='\r')) ++i;}
    bool lit(std::string_view w){if(s.substr(i,w.size())!=w) return false;i+=w.size();return true;}
    static void put(std::string& o,std::uint32_t cp){
        if(cp<0x80) o.push_back(static_cast<char>(cp));
        else if(cp<0x800){o.push_back(static_cast<char>(0xC0|(cp>>6)));o.push_back(static_cast<char>(0x80|(cp&0x3F)));}
        else if(cp<0x10000){o.push_back(static_cast<char>(0xE0|(cp>>12)));o.push_back(static_cast<char>(0x80|((cp>>6)&0x3F)));o.push_back(static_cast<char>(0x80|(cp&0x3F)));}
        else{o.push_back(static_cast<char>(0xF0|(cp>>18)));o.push_back(static_cast<char>(0x80|((cp>>12)&0x3F)));o.push_back(static_cast<char>(0x80|((cp>>6)&0x3F)));o.push_back(static_cast<char>(0x80|(cp&0x3F)));}
    }
    bool hex4(std::uint32_t& out){
        if(i+4>s.size()) return false;
        out=0;
        for(int k=0;k<4;++k){
            char c=s[i++];out<<=4;
            if(c>='0'&&c<='9') out|=static_cast<std::uint32_t>(c-'0');
            else if(c>='a'&&c<='f') out|=static_cast<std::uint32_t>(c-'a'+10);
            else if(c>='A'&&c<='F') out|=static_cast<std::uint32_t>(c-'A'+10);
            else return false;
        }
        return true;
    }
    bool str(std::string& o){
        if(i>=s.size()||s[i]!='"') return false;
        ++i;
        while(i<s.size()){
            char c=s[i++];
            if(c=='"') return true;
            if(static_cast<unsigned char>(c)<0x20) return false;
            if(c!='\\'){o.push_back(c);continue;}
            if(i>=s.size()) return false;
            char e=s[i++];
            switch(e){
            case '"':o.push_back('"');break;case '\\':o.push_back('\\');break;case '/':o.push_back('/');break;
            case 'b':o.push_back('\b');break;case 'f':o.push_back('\f');break;case 'n':o.push_back('\n');break;
            case 'r':o.push_back('\r');break;case 't':o.push_back('\t');break;
            case 'u':{
                std::uint32_t cp;if(!hex4(cp)) return false;
                if(cp>=0xD800&&cp<=0xDBFF){
                    std::uint32_t lo;
                    if(!lit("\\u")||!hex4(lo)||lo<0xDC00||lo>0xDFFF) return false;
                    cp=0x10000+((cp-0xD800)<<10)+(lo-0xDC00);
                }else if(cp>=0xDC00&&cp<=0xDFFF) return false;
                put(o,cp);break;}
            default:return false;
            }
        }
        return false;
    }
    bool value(Value& v){
        if(++depth>maxDepth) return false;
        ws();
        if(i>=s.size()) return false;
        bool ok=false;
        char c=s[i];
        if(c=='{'){
            v.kind=Kind::Object;++i;ws();
            if(i<s.size()&&s[i]=='}'){++i;ok=true;}
            else for(;;){
                ws();std::string k;if(!str(k)) break;
                ws();if(i>=s.size()||s[i]!=':') break;++i;
                Value child;if(!value(child)) break;
                v.object.emplace_back(std::move(k),std::move(child));
                ws();if(i<s.size()&&s[i]==','){++i;continue;}
                if(i<s.size()&&s[i]=='}'){++i;ok=true;}
                break;
            }
        }else if(c=='['){
            v.kind=Kind::Array;++i;ws();
            if(i<s.size()&&s[i]==']'){++i;ok=true;}
            else for(;;){
                Value child;if(!value(child)) break;
                v.array.push_back(std::move(child));
                ws();if(i<s.size()&&s[i]==','){++i;continue;}
                if(i<s.size()&&s[i]==']'){++i;ok=true;}
                break;
            }
        }else if(c=='"'){v.kind=Kind::String;ok=str(v.string);}
        else if(lit("true")){v.kind=Kind::Bool;v.boolean=true;ok=true;}
        else if(lit("false")){v.kind=Kind::Bool;ok=true;}
        else if(lit("null")){v.kind=Kind::Null;ok=true;}
        else if(c=='-'||(c>='0'&&c<='9')){
            std::size_t b=i;
            while(i<s.size()&&(s[i]=='-'||s[i]=='+'||s[i]=='.'||s[i]=='e'||s[i]=='E'||(s[i]>='0'&&s[i]<='9'))) ++i;
            try{v.number=std::stod(std::string(s.substr(b,i-b)));v.kind=Kind::Number;ok=true;}catch(...){ok=false;}
        }
        --depth;
        return ok;
    }
};
} // namespace detail

// Model responses use the 64 KiB default; project files and API payloads pass a larger cap.
inline std::optional<Value> parse(std::string_view text,std::size_t maxBytes=65536,int maxDepth=16){
    if(text.size()>maxBytes) return std::nullopt;
    detail::Parser p{text};
    p.maxDepth=maxDepth;
    Value v;
    if(!p.value(v)) return std::nullopt;
    p.ws();
    if(p.i!=text.size()) return std::nullopt;
    return v;
}

inline std::string quote(std::string_view s){
    std::string o="\"";
    for(char c:s){
        switch(c){
        case '"':o+="\\\"";break;case '\\':o+="\\\\";break;case '\n':o+="\\n";break;case '\r':o+="\\r";break;case '\t':o+="\\t";break;
        default:
            if(static_cast<unsigned char>(c)<0x20){static const char* h="0123456789abcdef";o+="\\u00";o.push_back(h[(c>>4)&0xF]);o.push_back(h[c&0xF]);}
            else o.push_back(c);
        }
    }
    o.push_back('"');
    return o;
}

} // namespace npc::dialogue::json
