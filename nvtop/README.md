# NVTOP

Monitor real-time information about your GPU status and running processes using nvtop.

# Features

* Uses `nvtop` to monitor real-time information about your GPU status.
* Multiple GPU support
* View processes that use GPU
* Processes columns: **PID**, **GPU Usage**, **Video Encoder Usage**, **Video Decoder Usage**, **GPU Memory Usage** and **Command Line**
* Processes can be ordered by any column. Just click the column header
* Customizable poll period
* Customizable colors for the sort column

![NVTOP panel](screenshots/panel.png)

## Plugin

| Field | Value |
| --- | --- |
| ID | `tordex/nvtop` |
| Entries | Panel: `panel` |

## Requirements

Plugin requires `nvtop`, `jq` and `pkill` to be installed into `$PATH`

## Usage

You can open the panel by bind it in your compositor or by setting the action for `sysmon` widgets:

![Actions](screenshots/actions.png)


```sh
noctalia msg panel-toggle tordex/nvtop:panel <order_by>
```

| `order_by` value   | Effect                        |
|--------------------|-------------------------------|
| `pid`              | Order by Process ID (PID)     |
| `gpu`              | Order by GPU Usage            |
| `enc`              | Order by Video Encoder Usage  |
| `dec`              | Order by Video Decoder Usage  |
| `mem`              | GPU Memory Usage              |
| `cmd`              | Order by Process Command Line |

Without `order_by` panel opens with previouse sort mode.

Add the `-` before `order_by` to reverse order. Example:

```sh
noctalia msg panel-toggle tordex/nvtop:panel -mem
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `delay` | `int` | `5` | Refresh rate. 1 == 0.1s. Valid values 1-20 |
| `sort_column_background` | `color` | `secondary` | The background color for the sort column. |
| `sort_column_color` | `color` | `on_secondary` | The text color for the sort column. |

