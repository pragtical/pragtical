@extends('layouts.app')

@section('content')
  <x-panel :title="$title">
    @foreach ($items as $item)
      @if ($item->enabled)
        <button class="item">{{ $item->label }}</button>
      @endif
    @endforeach
  </x-panel>
@endsection
