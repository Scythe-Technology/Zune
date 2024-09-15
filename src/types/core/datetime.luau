export type TimeDictionary = {
    year : number,
    month : number,
    day : number,
    hour : number,
    minute : number,
    second : number,
    millisecond : number,
};

export type DateTime = {
    unixTimestamp : number,
    unixTimestampMillis : number,
    
    UnixTimestamp : number,
    UnixTimestampMillis : number,

    toLocalTime : (self: DateTime) -> TimeDictionary;
    ToLocalTime : (self: DateTime) -> TimeDictionary;

    toUniversalTime : (self: DateTime) -> TimeDictionary;
    ToUniversalTime : (self: DateTime) -> TimeDictionary;

    toIsoDate : (self: DateTime) -> string;
    ToIsoDate : (self: DateTime) -> string;

    formatLocalTime : (self: DateTime, format: string) -> string;
    FormatLocalTime : (self: DateTime, format: string) -> string;

    formatUniversalTime : (self: DateTime, format: string) -> string;
    FormatUniversalTime : (self: DateTime, format: string) -> string;
};

local datetime = {};

datetime.now = (nil :: any) :: () -> DateTime;

datetime.fromIsoDate = (nil :: any) :: (date: string) -> DateTime;
datetime.fromUnixTimestamp = (nil :: any) :: (timestamp: number) -> DateTime;
datetime.fromUnixTimestampMillis = (nil :: any) :: (timestamp: number) -> DateTime;
datetime.fromLocalTime = (nil :: any) :: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime;
datetime.fromUniversalTime = (nil :: any) :: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime;

datetime.parse = (nil :: any) :: (date: string) -> DateTime;

return datetime;
