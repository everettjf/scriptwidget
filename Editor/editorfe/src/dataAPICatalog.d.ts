export type DataAPIValue = null | boolean | number | string | DataAPIValue[] | { [key: string]: DataAPIValue };
export interface DataAPI {
  id: string;
  group: "device" | "system" | "health" | "location" | "calendar" | "reminders" | "photos" | "services" | "music" | "notifications" | "maps" | "weather" | "alarms" | "documents" | "contacts" | "home";
  value: DataAPIValue;
  legacy?: string[];
  platforms: ("ios" | "macos")[];
  authorization: "none" | "healthRead" | "locationWhenInUse" | "calendarRead" | "remindersRead" | "remindersWrite" | "photosRead" | "serviceAccount" | "musicRead" | "systemAccess";
  notes: string;
  arguments: string[];
  asynchronous: boolean;
  minimumRuntimeVersion: string;
  nativeSource: string;
  operation: "authorization" | "availability" | "read" | "write";
  mock: "editable";
}
export const dataAPICatalog: DataAPI[];
